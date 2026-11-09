import AppKit
import Darwin
import SwiftUI

@MainActor
final class ConsoleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        guard CommandLine.arguments.contains("--startup-smoke") else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                   let view = window.contentView, view.bounds.width > 0, view.bounds.height > 0 {
                    view.displayIfNeeded()
                    guard Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil else {
                        FileHandle.standardError.write(Data("Bundled application icon is missing.\n".utf8))
                        Darwin.exit(2)
                    }
                    let marker = "{\"type\":\"bcr.native_startup\",\"first_frame\":true,\"icon\":true}\n"
                    FileHandle.standardOutput.write(Data(marker.utf8))
                    Darwin.exit(0)
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    FileHandle.standardError.write(Data("Native startup check was cancelled.\n".utf8))
                    Darwin.exit(2)
                }
            }
            FileHandle.standardError.write(Data("Native startup timed out before displaying a window.\n".utf8))
            Darwin.exit(2)
        }
    }
}

@main
@MainActor
struct BCRAgentConsoleApp: App {
    @NSApplicationDelegateAdaptor(ConsoleAppDelegate.self) private var appDelegate
    @StateObject private var model: ConsoleViewModel

    init() {
        let smoke = CommandLine.arguments.contains("--startup-smoke")
        _model = StateObject(wrappedValue: ConsoleViewModel(stores: smoke ? .temporary() : .standard, startsMIDI: !smoke))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1_200, minHeight: 760)
        }
        .defaultSize(width: 1_260, height: 920)
        .windowStyle(.hiddenTitleBar)
    }
}
