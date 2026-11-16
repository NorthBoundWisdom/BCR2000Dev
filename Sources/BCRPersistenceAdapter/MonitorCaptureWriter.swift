import BCRFoundation
import BCRSurfaceDomain
import Dispatch
import Foundation

public protocol CaptureEvidenceSink: AnyObject, Sendable {
    func write(_ data: Data) throws
    func synchronize() throws
    func close() throws
}

/// Exclusive creation never truncates an earlier recording or follows a final-component symlink.
public final class CaptureEvidenceFile: CaptureEvidenceSink, @unchecked Sendable {
    private let handle: FileHandle
    public init(url: URL) throws {
        handle = try LocalDataFile.createExclusive(url)
    }

    public func write(_ data: Data) throws { try handle.write(contentsOf: data) }
    public func synchronize() throws { try handle.synchronize() }
    public func close() throws { try handle.close() }
}

public struct CaptureWritingSnapshot: Equatable, Sendable {
    public enum Phase: String, Sendable { case starting, recording, stopping, finished, failed }
    public let phase: Phase
    public let eventCount: Int
    public let error: String?
    public var acceptsEvents: Bool { phase == .starting || phase == .recording }
}

/// One bounded mailbox and one background drain, independent of the screen's 300-event ring.
/// A full mailbox fails the recording visibly; it never drops or delays MIDI processing.
public final class MonitorCaptureWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.bcr.monitor-capture", qos: .utility)
    private let capacity: Int
    private var pending: [MonitorCaptureRecord]
    private var state = CaptureWritingSnapshot(phase: .starting, eventCount: 0, error: nil)
    private var draining = false
    private var sink: (any CaptureEvidenceSink)?
    private let url: URL
    private let sinkFactory: @Sendable (URL) throws -> any CaptureEvidenceSink
    private let onChange: @Sendable (CaptureWritingSnapshot) -> Void

    public init(url: URL, header: MonitorCaptureRecord, capacity: Int = 4096,
                sinkFactory: @escaping @Sendable (URL) throws
                    -> any CaptureEvidenceSink = { try CaptureEvidenceFile(url: $0) },
                onChange: @escaping @Sendable (CaptureWritingSnapshot) -> Void = { _ in })
    {
        precondition(capacity > 0)
        self.url = url; self.capacity = capacity; self.sinkFactory = sinkFactory; self.onChange = onChange
        pending = [header]
        scheduleDrain()
    }

    public var snapshot: CaptureWritingSnapshot { lock.withLock { state } }

    public func append(_ record: MonitorCaptureRecord) {
        for part in record.canonicalMIDI1Records { enqueue(part) }
    }

    private func enqueue(_ record: MonitorCaptureRecord) {
        let updated = lock.withLock { () -> CaptureWritingSnapshot? in
            guard state.acceptsEvents else { return nil }
            guard pending.count < capacity else {
                state = .init(phase: .failed, eventCount: state.eventCount,
                              error: L10n.text("录制队列已满；录制已停止，MIDI 处理继续。"))
                return state
            }
            var record = record
            record.fields["sequence"] = .number(state.eventCount + 1)
            pending.append(record)
            state = .init(phase: state.phase, eventCount: state.eventCount + 1, error: nil)
            return state
        }
        guard let updated else { return }
        if updated.phase == .failed { onChange(updated) }
        scheduleDrain()
    }

    public func finish(_ footer: MonitorCaptureRecord) {
        let updated = lock.withLock { () -> CaptureWritingSnapshot in
            guard state.acceptsEvents else { return state }
            var footer = footer
            footer.fields["eventCount"] = .number(state.eventCount)
            pending.append(footer) // One reserved terminal marker, even when the mailbox is full.
            state = .init(phase: .stopping, eventCount: state.eventCount, error: nil)
            return state
        }
        onChange(updated); scheduleDrain()
    }

    public func fail(_ message: String) {
        let failed = lock.withLock { () -> CaptureWritingSnapshot in
            guard state.phase != .finished else { return state }
            state = .init(phase: .failed, eventCount: state.eventCount, error: message)
            pending.removeAll(); return state
        }
        onChange(failed)
        queue.async { try? self.sink?.close(); self.sink = nil }
    }

    /// Barrier for explicit stop/testing. The caller suspends; MIDI remains on its own actor.
    public func flush() async -> CaptureWritingSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.snapshot) }
        }
    }

    private func scheduleDrain() {
        let start = lock.withLock { () -> Bool in
            guard !draining, state.phase != .failed, state.phase != .finished else { return false }
            draining = true; return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        do {
            if sink == nil { sink = try sinkFactory(url) }
            let started = lock.withLock { () -> CaptureWritingSnapshot in
                if state
                    .phase == .starting { state = .init(phase: .recording, eventCount: state.eventCount, error: nil) }
                return state
            }
            onChange(started)
            while true {
                let next = lock.withLock { () -> MonitorCaptureRecord? in
                    if state.phase == .failed { pending.removeAll(); draining = false; return nil }
                    guard !pending.isEmpty else { draining = false; return nil }
                    return pending.removeFirst()
                }
                guard let next else {
                    if snapshot.phase == .failed { try sink?.close(); sink = nil }
                    return
                }
                if next.kind == "capture-end" { try sink?.synchronize() }
                try sink?.write(next.encodedLine())
                if next.kind == "capture-end" {
                    try sink?.synchronize(); try sink?.close(); sink = nil
                    let done = lock.withLock { () -> CaptureWritingSnapshot in
                        state = .init(phase: .finished, eventCount: state.eventCount, error: nil)
                        draining = false; return state
                    }
                    onChange(done); return
                }
            }
        } catch {
            try? sink?.close(); sink = nil
            let failed = lock.withLock { () -> CaptureWritingSnapshot in
                state = .init(phase: .failed, eventCount: state.eventCount, error: error.localizedDescription)
                pending.removeAll(); draining = false; return state
            }
            onChange(failed)
        }
    }
}
