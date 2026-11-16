import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import Combine
import Foundation

/// Presentation and session subscription only; mailbox/file state lives in the portable writer.
@MainActor
final class MonitorCaptureController: ObservableObject {
    @Published private(set) var phase: CaptureWritingSnapshot.Phase = .finished
    @Published private(set) var error: String?
    @Published private(set) var url: URL?
    private let session: SurfaceSession
    private let directory: URL
    private let applicationVersion: String
    private var writer: MonitorCaptureWriter?
    private var observer: UUID?
    private var sessionID = ""
    private var mappingRevision: UInt64 = 0
    var isRecording: Bool { phase == .starting || phase == .recording }
    var canStart: Bool { phase == .finished || phase == .failed }

    init(session: SurfaceSession, directory: URL, applicationVersion: String = AppBuildVersion.current) {
        self.session = session; self.directory = directory; self.applicationVersion = applicationVersion
    }

    func start() {
        guard canStart else { return }
        do {
            sessionID = UUID().uuidString
            let header = try session.captureHeader(sessionID: sessionID, applicationVersion: applicationVersion)
            let destination = directory.appending(path: "midi-\(sessionID).jsonl")
            url = destination; error = nil; phase = .starting
            mappingRevision = session.mappingContextRevision
            writer = MonitorCaptureWriter(url: destination, header: header, sinkFactory: { url in
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                return try CaptureEvidenceFile(url: url)
            }, onChange: { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
            observer = session.observeCapture { [weak self] record in self?.receive(record) }
        } catch { self.error = error.localizedDescription; phase = .failed }
    }

    private func receive(_ record: MonitorCaptureRecord) {
        guard let writer else { return }
        if mappingRevision != session.mappingContextRevision {
            do {
                var context = try session.captureHeader(sessionID: sessionID, applicationVersion: applicationVersion)
                context.fields["kind"] = .string("event")
                context.fields["schemaVersion"] = nil
                context.fields["origin"] = .string("contextChanged")
                context.fields["timestamp"] = record.fields["timestamp"]
                context.fields["monotonicTimestamp"] = record.fields["monotonicTimestamp"]
                writer.append(context)
                mappingRevision = session.mappingContextRevision
            } catch { writer.fail(error.localizedDescription); return }
        }
        writer.append(record)
    }

    func stop() {
        if let observer { session.removeCaptureObserver(observer); self.observer = nil }
        guard let writer else { return }
        writer.finish(session.captureEnd(eventCount: writer.snapshot.eventCount))
        refresh()
    }

    func waitForWrites() async {
        _ = await writer?.flush()
        refresh()
    }

    private func refresh() {
        guard let state = writer?.snapshot else { return }
        phase = state.phase; error = state.error
        if phase == .failed || phase == .finished, let observer {
            session.removeCaptureObserver(observer); self.observer = nil
        }
    }
}
