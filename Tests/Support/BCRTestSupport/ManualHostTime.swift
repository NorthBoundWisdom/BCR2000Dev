import BCRFoundation
import Foundation

/// Main-actor deterministic sleeper. Cancellation removes and resumes the exact pending waiter.
@MainActor
public final class ManualHostTime {
    private struct Waiter {
        let deadline: Double
        let continuation: CheckedContinuation<Void, any Error>
    }

    public private(set) var now: Double
    private var waiters: [UUID: Waiter] = [:]
    public var pendingCount: Int { waiters.count }
    public var pendingDeadlines: [Double] { waiters.values.map(\.deadline).sorted() }
    public var nextDeadline: Double? { waiters.values.map(\.deadline).min() }
    public init(now: Double = 0) { self.now = now }
    public var time: HostTime {
        HostTime(now: { self.now }, sleep: { try await self.sleep($0) })
    }

    public func advance(by seconds: Double) {
        precondition(seconds >= 0 && seconds.isFinite)
        now += seconds
        let due = waiters.filter { $0.value.deadline <= now }
        for (id, waiter) in due {
            waiters[id] = nil
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
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }
}
