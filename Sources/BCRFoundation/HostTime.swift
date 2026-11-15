import Foundation

/// Host scheduling and elapsed time share one monotonic source. Deadlines and cancellation remain
/// observable when tests substitute a manual clock; production always uses ContinuousClock sleep.
@MainActor
public struct HostTime {
    public let now: @MainActor () -> Double
    public let sleep: @MainActor (Duration) async throws -> Void

    public init(now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
    {
        self.now = now; self.sleep = sleep
    }

    public static var live: Self { .init() }
    /// For finite background work only. Periodic drivers must use live or manually advanced time.
    public static var immediate: Self { .init(sleep: { _ in try Task.checkCancellation(); await Task.yield() }) }
}
