import Foundation

/// CoreMIDI can synchronously wait for system drivers for tens of seconds. The
/// queue owns that call; the main actor only awaits the completion value.
enum CoreMIDIStartup {
    static func run(on queue: DispatchQueue, operation: @escaping @Sendable () throws -> Void) async throws {
        try await begin(on: queue, operation: operation).value()
    }

    /// Dispatches the operation immediately, before the caller next yields the main actor, so
    /// slow system initialization overlaps the first window layout instead of waiting behind it.
    static func begin(on queue: DispatchQueue, operation: @escaping @Sendable () throws -> Void) -> Pending {
        let pending = Pending()
        queue.async {
            do { try operation(); pending.finish(.success(())) }
            catch { pending.finish(.failure(error)) }
        }
        return pending
    }

    /// One startup result, awaited by at most one caller (the service's initialization task).
    final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, any Error>?
        private var waiter: CheckedContinuation<Void, any Error>?

        fileprivate func finish(_ value: Result<Void, any Error>) {
            let waiter: CheckedContinuation<Void, any Error>? = lock.withLock {
                result = value
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume(with: value)
        }

        func value() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready: Result<Void, any Error>? = lock.withLock {
                    precondition(waiter == nil, "CoreMIDI startup has a single awaiting task")
                    if result == nil { waiter = continuation }
                    return result
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }
}
