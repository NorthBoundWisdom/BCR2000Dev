import AppKit

/// Test-only presentation: accessory activation policy, transparent windows and mouse passthrough.
/// Transparency and passthrough provide visual/pointer isolation. Accessory policy does not prevent
/// every native dialog from activating the app; only audit-validated scenarios may run unattended.
/// Parking outside the displays is best effort: SwiftUI may constrain the frame back onto a screen.
/// Layout, view rendering and the accessibility tree keep working.
///
/// Honoured only together with a test mode, so an ordinary launch can never become invisible.
@MainActor
enum OffscreenPresentation {
    static let isEnabled = enabled(arguments: CommandLine.arguments)
    /// Initial parking hint, not a guarantee about later SwiftUI-controlled frame coordinates.
    static let origin = NSPoint(x: -30_000, y: -30_000)
    private static var observers: [any NSObjectProtocol] = []

    static func enabled(arguments: [String]) -> Bool {
        arguments.contains("--offscreen")
            && (arguments.contains("--startup-smoke") || arguments.contains("--integration-test"))
    }

    /// AppKit notifications cover newly created windows/sheets and later presentation changes.
    static func install() {
        guard isEnabled, observers.isEmpty else { return }
        observers = observeWindows(center: .default) { NSApp.windows }
    }

    /// The injected registry lets tests cover several never-ordered-in windows without using the desktop.
    static func observeWindows(center: NotificationCenter,
                               windows: @escaping @MainActor () -> [NSWindow]) -> [any NSObjectProtocol]
    {
        let maintain: @MainActor () -> Void = {
            for window in windows() {
                if window.alphaValue != 0 {
                    apply(to: window)
                } else if !window.ignoresMouseEvents {
                    window.ignoresMouseEvents = true
                }
                // Do not chase coordinates on every move: SwiftUI can constrain them again,
                // and an observer-induced move must not create a frame-placement feedback loop.
            }
        }
        let names = [
            NSApplication.didUpdateNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didUpdateNotification, NSWindow.willBeginSheetNotification,
            NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification
        ]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { maintain() }
            }
        }
        maintain()
        return tokens
    }

    static func conceal(_ window: NSWindow) {
        guard isEnabled else { return }
        apply(to: window)
    }

    static func apply(to window: NSWindow) {
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        // Sheets follow their parent; moving them independently would detach them.
        if window.sheetParent == nil, window.frame.origin != origin { window.setFrameOrigin(origin) }
    }
}
