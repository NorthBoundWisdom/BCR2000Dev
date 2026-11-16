import BCRFoundation
import BCRSurfaceDomain
import Foundation

/// All memory held across a queue boundary is charged until its consumer finishes.
final class OwnedIngressBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limits: (tasks: Int, units: Int, bytes: Int)
    private let byteAccounting: String
    private var tasks = 0, units = 0, bytes = 0, peakTasks = 0, peakUnits = 0, peakBytes = 0, rejected = 0
    private var closed = false
    init(tasks: Int, units: Int, bytes: Int, byteAccounting: String) {
        limits = (tasks, units, bytes); self.byteAccounting = byteAccounting
    }

    func reserve(units cost: Int, bytes size: Int) -> OwnedVirtualInputTicket? {
        lock.lock()
        guard !closed, cost > 0, size > 0, tasks < limits.tasks,
              cost <= limits.units - units, size <= limits.bytes - bytes
        else {
            closed = true; rejected = min(rejected, Int.max - 1) + 1; lock.unlock(); return nil
        }
        tasks += 1; units += cost; bytes += size
        peakTasks = max(peakTasks, tasks); peakUnits = max(peakUnits, units); peakBytes = max(peakBytes, bytes)
        lock.unlock()
        return OwnedVirtualInputTicket { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            precondition(self.tasks > 0 && self.units >= cost && self.bytes >= size)
            self.tasks -= 1; self.units -= cost; self.bytes -= size
        }
    }

    func close() { lock.lock(); closed = true; lock.unlock() }
    func reopen() { lock.lock(); closed = false; lock.unlock() }
    var audit: JSONValue {
        lock.lock(); defer { lock.unlock() }
        return .object([
            "pending_tasks": .number(tasks),
            "pending_units": .number(units),
            "pending_bytes": .number(bytes),
            "peak_tasks": .number(peakTasks),
            "peak_units": .number(peakUnits),
            "peak_bytes": .number(peakBytes),
            "limit_tasks": .number(limits.tasks),
            "limit_units": .number(limits.units),
            "limit_bytes": .number(limits.bytes),
            "byte_accounting": .string(byteAccounting),
            "rejected": .number(rejected),
            "closed": .bool(closed)
        ])
    }
}

/// Callback-side mirror of canonical ownership. Sealing happens before any fault task is queued.
final class OwnedIngressControl: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt = 0
    private var connected = false, blocked = false, stopped = false
    private var endpoints: Set<UInt32> = []
    private var notificationPending = false, notificationDirty = false
    private var notificationEnqueued = 0, notificationCoalesced = 0, unrelated = 0, stale = 0
    func publish(generation: UInt, connected: Bool, endpoints: Set<UInt32>, reopen: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        self.generation = generation; self.connected = connected; self.endpoints = endpoints
        if reopen { blocked = false }
    }

    func seal() -> UInt? {
        lock.lock(); defer { lock.unlock() }
        guard !blocked, !stopped else { return nil }
        blocked = true; return generation
    }

    func stop() { lock.lock(); stopped = true; blocked = true; connected = false; lock.unlock() }
    func current(requireConnection: Bool = false) -> UInt? {
        lock.lock(); defer { lock.unlock() }
        return !stopped && !blocked && (!requireConnection || connected) ? generation : nil
    }

    func admits(_ tagged: UInt, requireConnection: Bool = true) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let allowed = !stopped && !blocked && tagged == generation && (!requireConnection || connected)
        if !allowed { stale = min(stale, Int.max - 1) + 1 }
        return allowed
    }

    func notify(_ object: UInt32) -> UInt? {
        lock.lock(); defer { lock.unlock() }
        guard endpoints.contains(object) else { unrelated = min(unrelated, Int.max - 1) + 1; return nil }
        guard !blocked, !stopped else { return nil }
        if notificationPending {
            notificationDirty = true; notificationCoalesced = min(notificationCoalesced, Int.max - 1) + 1; return nil
        }
        notificationPending = true; notificationEnqueued = min(notificationEnqueued, Int.max - 1) + 1
        return generation
    }

    /// Retain the single slot when dirty; queue another bounded pass so IO cannot starve other work.
    func finishNotification() -> UInt? {
        lock.lock(); defer { lock.unlock() }
        if notificationDirty, !blocked, !stopped {
            notificationDirty = false; notificationEnqueued = min(notificationEnqueued, Int.max - 1) + 1
            return generation
        }
        notificationPending = false; notificationDirty = false; return nil
    }

    var audit: JSONValue {
        lock.lock(); defer { lock.unlock() }
        return .object(["generation": .number(Int(generation)), "blocked": .bool(blocked), "stopped": .bool(stopped),
                        "notification_pending": .number(notificationPending ? 1 : 0),
                        "notification_enqueued": .number(notificationEnqueued),
                        "notification_coalesced": .number(notificationCoalesced),
                        "unrelated_notifications": .number(unrelated), "stale_ingress": .number(stale)])
    }
}

struct OwnedVirtualWire: Sendable {
    let words: [UInt32]
    let timestamps: [UInt64]
    init(words: [UInt32], timestamps: [UInt64]? = nil) {
        self.words = words; self.timestamps = timestamps ?? Array(repeating: 0, count: words.count)
    }

    /// This backend supports only complete group-zero MIDI1 CC/note words. No partial decode or masking.
    func decoded() throws -> [MIDIVoiceMessage] {
        guard !words.isEmpty, words.count <= 256, timestamps.count == words.count,
              words.allSatisfy({ word in
                  word >> 24 == 0x20 && [UInt32(8), 9, 11].contains((word >> 20) & 15) &&
                      word & 0x00008080 == 0
              }) else { throw OwnedVirtualError.invalidMessage }
        let decoded = words.compactMap(MIDI1UMPCodec.decode(word:))
        guard decoded.count == words.count else { throw OwnedVirtualError.invalidMessage }
        return decoded
    }
}

struct OwnedPeerBatch: Sendable {
    let lines: [Data]
    let receivedAt: Double
    let generation: UInt
    let ticket: OwnedVirtualInputTicket
}
