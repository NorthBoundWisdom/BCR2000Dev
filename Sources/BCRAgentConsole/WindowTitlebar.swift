import AppKit
import SwiftUI

/// Restores double-click zoom for the custom, untitled chrome.
/// Single clicks pass through to AppKit for dragging; window movement never changes SwiftUI state.
@MainActor
struct WindowTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTitlebarView {
        WindowTitlebarView()
    }

    func updateNSView(_ nsView: WindowTitlebarView, context: Context) {}

    static func dismantleNSView(_ nsView: WindowTitlebarView, coordinator: ()) {
        nsView.detach()
    }
}

@MainActor
final class WindowTitlebarView: NSView {
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard window != nil else { return }
        // AppKit local event monitors execute on the application's main thread.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handleTitlebarMouseDown(event) ?? false
            }
            return handled ? nil : event
        }
    }

    func detach() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    func handleTitlebarMouseDown(_ event: NSEvent) -> Bool {
        guard let window, event.window === window,
              !window.styleMask.contains(.fullScreen),
              event.locationInWindow.y >= window.contentLayoutRect.maxY else { return false }
        // Traffic-light buttons retain their own click and accessibility behaviour.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind),
               button.convert(button.bounds, to: nil).insetBy(dx: -4, dy: -4).contains(event.locationInWindow) {
                return false
            }
        }
        if event.clickCount == 2 {
            window.performZoom(nil)
            return true
        }
        return false
    }
}
