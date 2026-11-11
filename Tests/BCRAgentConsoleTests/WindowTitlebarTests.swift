import AppKit
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

@MainActor
private final class ZoomRecordingWindow: NSWindow {
    var zoomCount = 0

    override func performZoom(_ sender: Any?) {
        zoomCount += 1
    }
}

@MainActor
final class WindowTitlebarTests: XCTestCase {
    private func makeWindow() -> ZoomRecordingWindow {
        _ = NSApplication.shared
        let window = ZoomRecordingWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1_200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        return window
    }

    private func event(in window: NSWindow, at point: NSPoint, clicks: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: clicks, pressure: 1
        ))
    }

    func testDoubleClickInCustomTitlebarZooms() async throws {
        let window = makeWindow()
        let view = WindowTitlebarView()
        window.contentView?.addSubview(view)
        defer { view.detach(); window.close() }
        let click = try event(in: window, at: NSPoint(x: 500, y: window.frame.height - 14), clicks: 2)

        XCTAssertTrue(view.handleTitlebarMouseDown(click))
        XCTAssertEqual(window.zoomCount, 1)
    }

    func testSingleClickPassesThroughForNativeWindowDragging() async throws {
        let window = makeWindow()
        let view = WindowTitlebarView()
        window.contentView?.addSubview(view)
        defer { view.detach(); window.close() }
        let click = try event(in: window, at: NSPoint(x: 500, y: window.frame.height - 14), clicks: 1)

        XCTAssertFalse(view.handleTitlebarMouseDown(click))
        XCTAssertEqual(window.zoomCount, 0)
    }

    func testContentDoubleClickDoesNotZoom() async throws {
        let window = makeWindow()
        let view = WindowTitlebarView()
        window.contentView?.addSubview(view)
        defer { view.detach(); window.close() }
        let click = try event(in: window, at: NSPoint(x: 500, y: 100), clicks: 2)

        XCTAssertFalse(view.handleTitlebarMouseDown(click))
        XCTAssertEqual(window.zoomCount, 0)
    }

    func testTrafficLightButtonsKeepTheirOwnActions() async throws {
        let window = makeWindow()
        let view = WindowTitlebarView()
        window.contentView?.addSubview(view)
        defer { view.detach(); window.close() }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let bounds = button.convert(button.bounds, to: nil)
            let click = try event(in: window, at: NSPoint(x: bounds.midX, y: bounds.midY), clicks: 2)
            XCTAssertFalse(view.handleTitlebarMouseDown(click))
        }
        XCTAssertEqual(window.zoomCount, 0)
    }

    func testOtherWindowIsNotIntercepted() async throws {
        let window = makeWindow()
        let other = makeWindow()
        let view = WindowTitlebarView()
        window.contentView?.addSubview(view)
        defer { view.detach(); window.close(); other.close() }
        let click = try event(in: other, at: NSPoint(x: 500, y: other.frame.height - 14), clicks: 2)

        XCTAssertFalse(view.handleTitlebarMouseDown(click))
        XCTAssertEqual(window.zoomCount, 0)
        XCTAssertEqual(other.zoomCount, 0)
    }
}
