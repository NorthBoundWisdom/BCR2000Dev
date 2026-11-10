import AppKit
import Darwin
import SwiftUI

@MainActor
final class ConsoleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url)
        {
            NSApp.applicationIconImage = icon
        }
        guard CommandLine.arguments.contains("--startup-smoke") else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                   let view = window.contentView, view.bounds.width > 0, view.bounds.height > 0
                {
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
        if CommandLine.arguments.contains("--integration-test") {
            #if DEBUG
                do {
                    guard !smoke else { throw MCPHTTPParseError(reason: "集成测试与 startup-smoke 不能同时启用") }
                    let context = try IntegrationTestContext(environment: ProcessInfo.processInfo.environment)
                    _model = StateObject(wrappedValue: ConsoleViewModel(
                        stores: context.stores, startsMIDI: false,
                        mcpCredentials: context.credentials, integrationTest: true
                    ))
                    return
                } catch {
                    FileHandle.standardError.write(Data(("隔离测试启动失败：" + error.localizedDescription + "\n").utf8))
                    Darwin.exit(2)
                }
            #else
                FileHandle.standardError.write(Data("隔离测试仅支持 Debug 构建。\n".utf8))
                Darwin.exit(2)
            #endif
        }
        _model = StateObject(wrappedValue: ConsoleViewModel(
            stores: smoke ? .temporary() : .standard,
            startsMIDI: !smoke
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1_200, minHeight: 760)
                .background(WindowTitlebar().frame(width: 0, height: 0))
        }
        .defaultSize(width: 1_260, height: 920)
        .windowStyle(.hiddenTitleBar)
    }
}
