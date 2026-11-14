import AppKit
import Foundation

// A disposable, explicitly foreground CI fixture, separate from the audited app.
// It provides a real AX focus owner without opening user documents or changing TCC.
@MainActor
final class FocusHostDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        view.string = "CI desktop focus baseline"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "CI desktop focus baseline"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        FileHandle.standardError.write(Data(
            "bcr.desktop_focus_host.window_created pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8
        ))
    }
}

let app = NSApplication.shared
let delegate = FocusHostDelegate()
app.delegate = delegate
app.run()
