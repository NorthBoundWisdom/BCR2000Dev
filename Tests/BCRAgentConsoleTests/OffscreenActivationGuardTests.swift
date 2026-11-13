import AppKit
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class ActivationProbe: NSObject {
    var calls = 0
    @objc dynamic func activate() { calls += 1 }
    @objc dynamic func activateIgnoringOtherApps(_ flag: Bool) { calls += flag ? 10 : 1 }
}

@MainActor
final class OffscreenActivationGuardTests: XCTestCase {
    func testBothActivationSelectorsAreSuppressedOnlyOnTheSelectedClass() {
        let probe = ActivationProbe()
        probe.activate()
        probe.activateIgnoringOtherApps(true)
        XCTAssertEqual(probe.calls, 11)
        XCTAssertTrue(OffscreenActivationGuard.install(on: ActivationProbe.self))
        probe.activate()
        probe.activateIgnoringOtherApps(true)
        probe.activateIgnoringOtherApps(false)
        XCTAssertEqual(probe.calls, 11)
    }

    func testUnrelatedClassCannotInstallActivationOverrides() {
        XCTAssertFalse(OffscreenActivationGuard.install(on: NSObject.self))
    }
}
