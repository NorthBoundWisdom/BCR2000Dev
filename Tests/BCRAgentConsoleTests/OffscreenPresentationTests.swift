import AppKit
import XCTest
@testable import BCRAgentConsole

@MainActor
final class OffscreenPresentationTests: XCTestCase {
    func testOnlyTestModesCanBecomeInvisible() {
        XCTAssertTrue(OffscreenPresentation.enabled(arguments: ["app", "--startup-smoke", "--offscreen"]))
        XCTAssertTrue(OffscreenPresentation.enabled(arguments: ["app", "--integration-test", "--offscreen"]))
        // An ordinary launch must never end up with an invisible, click-through window.
        XCTAssertFalse(OffscreenPresentation.enabled(arguments: ["app", "--offscreen"]))
        XCTAssertFalse(OffscreenPresentation.enabled(arguments: ["app", "--startup-smoke"]))
        XCTAssertFalse(OffscreenPresentation.isEnabled)
    }

    func testConcealedWindowIsTransparentClickThroughAndOutsideEveryScreen() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        OffscreenPresentation.apply(to: window)
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertFalse(window.isVisible, "concealing must not order the window in")
        for screen in NSScreen.screens { XCTAssertFalse(screen.frame.intersects(window.frame)) }
        // Without the test flags the same call path is a no-op.
        let ordinary = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: true)
        ordinary.isReleasedWhenClosed = false
        OffscreenPresentation.conceal(ordinary)
        XCTAssertEqual(ordinary.alphaValue, 1)
        XCTAssertFalse(ordinary.ignoresMouseEvents)
    }
}
