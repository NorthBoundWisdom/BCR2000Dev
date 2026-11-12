import BCRFoundation
import BCRMCPAdapter
import BCRProviderMCPAdapter
import BCRSurfaceDomain
import Foundation
import SurfaceControlContracts
import XCTest

@MainActor
final class TimingIsolationEvidenceTests: XCTestCase {
    @MainActor
    private final class Completion {
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?
        func finish() {
            finished = true
            continuation?.resume(); continuation = nil
        }

        func wait() async {
            if finished { return }
            await withCheckedContinuation { continuation = $0 }
        }
    }

    private final class Marker {
        weak var previous: BCRSurfaceControlAdapter?
        var cleanupStarted: Double?
        var cleanupFinished: Double?
        var timerFired: Double?
    }

    private func slowCleanup(_ marker: Marker) {
        marker.cleanupStarted = ProcessInfo.processInfo.systemUptime
        // Deliberate test-only cleanup cost; no production scheduler or threshold is changed.
        Thread.sleep(forTimeInterval: 0.15)
        marker.cleanupFinished = ProcessInfo.processInfo.systemUptime
    }

    func testPreviousAdapterCleanupCanCrossIntoNextTimerMeasurement() async throws {
        let marker = Marker()
        let cleanupDone = Completion(), timerDone = Completion()
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: session, permissions: .init(deviceControl: true),
                                            includeAgent: false)
        var adapter: BCRSurfaceControlAdapter? = try BCRSurfaceControlAdapter(
            surface: session, instanceID: "queue-evidence", permissions: .init(input: true),
            holdScheduler: { [self] _, _ in { self.slowCleanup(marker); cleanupDone.finish() } }
        )
        let discovery = try XCTUnwrap(adapter).discovery()
        _ = try XCTUnwrap(adapter).execute(.input(.init(
            expected: discovery.expected, expectedSequence: discovery.latest_sequence,
            controlID: "button.1.3", encoding: "boolean", value: .bool(true), holdSeconds: 1
        )), gateway: gateway)
        marker.previous = adapter
        adapter = nil
        XCTAssertNil(marker.previous)
        // The production deinit queues cancellation on the actor; the synchronous fixture is gone
        // while its cleanup is still outstanding. A following XCTest can already begin here.
        XCTAssertNil(marker.cleanupStarted)
        let start = ProcessInfo.processInfo.systemUptime
        let cancel = BCRSurfaceControlAdapter.defaultHoldScheduler(0.01) {
            marker.timerFired = ProcessInfo.processInfo.systemUptime
            timerDone.finish()
        }
        defer { cancel() }
        // Await the actual injected cancellation and timer completions, not a guessed drain delay.
        await cleanupDone.wait()
        await timerDone.wait()
        let cleanupStart = try XCTUnwrap(marker.cleanupStarted)
        let cleanupEnd = try XCTUnwrap(marker.cleanupFinished)
        let fired = try XCTUnwrap(marker.timerFired)
        XCTAssertGreaterThanOrEqual(cleanupStart, start)
        XCTAssertGreaterThanOrEqual(cleanupEnd - cleanupStart, 0.15)
        XCTAssertGreaterThanOrEqual(fired, cleanupEnd)
        XCTAssertGreaterThan(fired - (start + 0.01), 0.1)
        print("TIMING_QUEUE_EVIDENCE cleanup_s=\(cleanupEnd - cleanupStart) lag_s=\(fired - (start + 0.01))")
    }
}
