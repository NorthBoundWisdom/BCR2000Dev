import Foundation

/// CoreMIDI can synchronously wait for system drivers for tens of seconds. The
/// queue owns that call; the main actor only awaits the completion value.
enum CoreMIDIStartup {
    static func run(on queue: DispatchQueue, operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do { try operation(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
