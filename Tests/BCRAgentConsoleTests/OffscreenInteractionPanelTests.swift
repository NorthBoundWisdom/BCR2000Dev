import AppKit
import SwiftUI
import XCTest
@testable import BCRAgentConsole

@MainActor
final class OffscreenInteractionPanelTests: XCTestCase {
    func testInteractionCarrierCannotBecomeKeyOrMainAndStartsHidden() {
        _ = NSApplication.shared
        let panel = OffscreenInteractionWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                               styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        OffscreenPresentation.apply(to: panel)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isVisible, "Unit tests must not order a window onto the desktop")
    }

    func testOrdinaryLaunchCannotCreateAnOffscreenInteractionCarrier() {
        XCTAssertFalse(OffscreenPresentation.isEnabled)
        OffscreenInteractionPanel.present(id: "ordinary", view: AnyView(EmptyView()))
        XCTAssertNil(OffscreenInteractionPanel.window)
    }
}
