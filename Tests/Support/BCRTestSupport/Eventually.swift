import Foundation

/// A condition that did not become true before its deadline. Thrown so the test stops with a
/// description instead of asserting on a state that has not been reached yet.
public struct WaitTimeout: Error, CustomStringConvertible {
    public let description: String
}

/// Polls `condition` on the main actor until it holds. Tests wait for the state they assert on
/// instead of sleeping a fixed time, so a slow or loaded machine only makes them slower, never red.
/// The deadline is deliberately generous; a passing run returns as soon as the condition holds.
@MainActor
public func waitUntil(
    _ description: @autoclosure () -> String = "condition",
    timeout: Duration = .seconds(10),
    _ condition: @MainActor () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try !condition() {
        guard ContinuousClock.now < deadline else {
            throw WaitTimeout(description: "Timed out after \(timeout) waiting for \(description())")
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// A counter that `@Sendable` callbacks from other actors or threads can bump while a test polls it.
public final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    public init() {}
    public func increment() { lock.withLock { count += 1 } }
    public var value: Int { lock.withLock { count } }
}
