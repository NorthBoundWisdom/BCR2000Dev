import BCRFoundation
import Foundation

/// Main-actor deterministic sleeper. Cancellation removes and resumes the exact pending waiter.
@MainActor
public final class ManualHostTime {
    public struct Transition: Encodable, Sendable {
        public let phase: String
        public let id: String
        public let now: Double
        public let deadline: Double
    }

    public private(set) var completedSleepCount = 0
    public private(set) var transitions: [Transition] = []
    private let recordTransitions: Bool
    private func record(_ phase: String, id: UUID, deadline: Double) {
        if recordTransitions {
            transitions.append(.init(phase: phase, id: id.uuidString, now: now, deadline: deadline))
        }
    }

    private struct Waiter {
        let deadline: Double
        let continuation: CheckedContinuation<Void, any Error>
    }

    public private(set) var now: Double
    private var waiters: [UUID: Waiter] = [:]
    public var pendingCount: Int { waiters.count }
    public var pendingDeadlines: [Double] { waiters.values.map(\.deadline).sorted() }
    public var nextDeadline: Double? { waiters.values.map(\.deadline).min() }
    public init(now: Double = 0, recordTransitions: Bool = false) {
        self.now = now; self.recordTransitions = recordTransitions
    }

    public var time: HostTime {
        HostTime(now: { self.now }, sleep: { try await self.sleep($0) })
    }

    public func advance(by seconds: Double) {
        precondition(seconds >= 0 && seconds.isFinite)
        now += seconds
        let due = waiters.filter { $0.value.deadline <= now }
        for (id, waiter) in due {
            waiters[id] = nil
            record("resumed", id: id, deadline: waiter.deadline)
            waiter.continuation.resume()
        }
    }

    private func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        guard seconds > 0 else { return }
        let id = UUID(), deadline = now + seconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                record("registered", id: id, deadline: deadline)
            }
        } onCancel: {
            Task { @MainActor in
                if let waiter = self.waiters.removeValue(forKey: id) {
                    self.record("cancelled", id: id, deadline: waiter.deadline)
                    waiter.continuation.resume(throwing: CancellationError())
                }
            }
        }
        try Task.checkCancellation()
        completedSleepCount += 1
        record("completed", id: id, deadline: deadline)
    }
}
