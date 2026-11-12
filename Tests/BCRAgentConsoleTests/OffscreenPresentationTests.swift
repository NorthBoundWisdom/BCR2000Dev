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

    func testNotificationsConcealAllCurrentAndNewWindowsWithoutOrderingThemIn() {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let registry = OffscreenWindowRegistry()
        let first = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: true)
        first.isReleasedWhenClosed = false
        registry.windows = [first]
        let tokens = OffscreenPresentation.observeWindows(center: center) { registry.windows }
        defer { for token in tokens { center.removeObserver(token) } }
        XCTAssertEqual(first.alphaValue, 0)
        let second = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        second.isReleasedWhenClosed = false
        registry.windows.append(second)
        center.post(name: NSWindow.willBeginSheetNotification, object: first)
        for window in registry.windows {
            XCTAssertEqual(window.alphaValue, 0)
            XCTAssertTrue(window.ignoresMouseEvents)
            XCTAssertFalse(window.isVisible)
        }
        second.alphaValue = 1
        second.ignoresMouseEvents = false
        center.post(name: NSWindow.didUpdateNotification, object: second)
        XCTAssertEqual(second.alphaValue, 0)
        XCTAssertTrue(second.ignoresMouseEvents)
    }

    func testMaintenanceDoesNotChaseFramesAndStopsWhenObserversAreRemoved() {
        _ = NSApplication.shared
        let center = NotificationCenter()
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let tokens = OffscreenPresentation.observeWindows(center: center) { [window] }
        window.setFrameOrigin(.zero)
        window.ignoresMouseEvents = false
        center.post(name: NSWindow.didMoveNotification, object: window)
        XCTAssertEqual(window.frame.origin, .zero, "SwiftUI-controlled coordinates do not define invisibility")
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        for token in tokens { center.removeObserver(token) }
        window.alphaValue = 1
        center.post(name: NSApplication.didUpdateNotification, object: nil)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.isVisible)
    }
}

@MainActor
private final class OffscreenWindowRegistry {
    var windows: [NSWindow] = []
}
