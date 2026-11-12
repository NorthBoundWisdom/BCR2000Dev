import AppKit

/// Test-only presentation: no Dock icon, no activation, and every window transparent, click-through
/// and parked outside all screens. Routine smoke and integration runs then never cover or take
/// focus from whatever else is on the desktop. Layout, rendering to bitmaps and the accessibility
/// tree keep working.
///
/// Honoured only together with a test mode, so an ordinary launch can never become invisible.
@MainActor
enum OffscreenPresentation {
    static let isEnabled = enabled(arguments: CommandLine.arguments)
    /// Far outside any display arrangement; AppKit only constrains a title bar against the top edge.
    static let origin = NSPoint(x: -30_000, y: -30_000)
    private static var keeper: Task<Void, Never>?
    private static var observers: [any NSObjectProtocol] = []

    static func enabled(arguments: [String]) -> Bool {
        arguments.contains("--offscreen")
            && (arguments.contains("--startup-smoke") || arguments.contains("--integration-test"))
    }

    /// Windows created later (settings, panels) and frames restored by SwiftUI are parked again.
    static func install() {
        guard isEnabled, keeper == nil else { return }
        // Sheets, dialogs and menus appear between polls; hide them in the same event-loop pass.
        let names = [
            NSApplication.didUpdateNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didUpdateNotification, NSWindow.willBeginSheetNotification
        ]
        for name in names {
            // AppKit posts these on the main thread; the notification itself is not needed.
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { for window in NSApp.windows { apply(to: window) } }
            })
        }
        keeper = Task { @MainActor in
            while !Task.isCancelled {
                for window in NSApp.windows { apply(to: window) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
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
