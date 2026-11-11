import BCRAgentCore
import BCRProviderApplication
import AppKit
import Darwin
import SwiftUI

@MainActor
final class ConsoleAppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
        var snapshotModel: ConsoleViewModel?
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url)
        {
            NSApp.applicationIconImage = icon
        }
        guard CommandLine.arguments.contains("--startup-smoke") else { return }
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline {
                if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }),
                   let view = window.contentView
                {
                    window.setContentSize(NSSize(width: 1_200, height: 760))
                    window.makeKeyAndOrderFront(nil)
                    guard window.isVisible, view.bounds.width > 0, view.bounds.height > 0 else {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    view.layoutSubtreeIfNeeded()
                    view.displayIfNeeded()
                    guard Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil else {
                        FileHandle.standardError.write(Data("Bundled application icon is missing.\n".utf8))
                        Darwin.exit(2)
                    }
                    #if DEBUG
                        if CommandLine.arguments.contains("--render-ui") {
                            do {
                                guard let path = ProcessInfo.processInfo.environment["BCR_UI_SNAPSHOT_DIRECTORY"],
                                      path.hasPrefix("/"),
                                      let model = self.snapshotModel
                                else { throw CocoaError(.fileWriteInvalidFileName) }
                                let directory = URL(fileURLWithPath: path)
                                try await renderNativeUISnapshots(model: model, directory: directory)
                                // The real window shows the title strip and safe-area layout the previews cannot.
                                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                                else { throw CocoaError(.fileWriteUnknown) }
                                view.cacheDisplay(in: view.bounds, to: bitmap)
                                guard let data = bitmap.representation(using: .png, properties: [:])
                                else { throw CocoaError(.fileWriteUnknown) }
                                try data.write(to: directory.appending(path: "main-window.png"))
                            } catch {
                                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                                Darwin.exit(2)
                            }
                        }
                    #endif
                    let marker = "{\"type\":\"bcr.native_startup\",\"first_frame\":true,\"icon\":true,\"clientVersion\":\"\(AppBuildVersion.current)\",\"language\":\"\(L10n.language.rawValue)\",\"settings\":\"\(L10n.text("设置"))\"}\n"
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
            let windows = NSApp.windows.map {
                "main=\($0.canBecomeMain), visible=\($0.isVisible), frame=\($0.frame), content=\(String(describing: $0.contentView))"
            }.joined(separator: "\n")
            FileHandle.standardError.write(Data(
                "Native startup timed out before displaying a window. active=\(NSApp.isActive) windows=\(NSApp.windows.count)\n\(windows)\n"
                    .utf8
            ))
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
        let providerConfiguration = ProviderConfiguration(
            robot: CommandLine.arguments.contains("--robot-sim"),
            chassis: CommandLine.arguments.contains("--chassis-sim")
        )
        var pipedCredentials: (any MCPCredentialStore)?
        if CommandLine.arguments.contains("--mcp-token-stdin") {
            do {
                var info = stat()
                guard !smoke, !CommandLine.arguments.contains("--integration-test"),
                      fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO
                else { throw MCPHTTPParseError(reason: L10n.text("MCP 凭据必须从专用管道传入")) }
                pipedCredentials = try PipedMCPCredentialStore(data: FileHandle.standardInput
                    .read(upToCount: 65) ?? Data())
            } catch {
                FileHandle.standardError.write(Data((L10n.text("MCP 管道凭据无效") + "\n").utf8))
                Darwin.exit(2)
            }
        }
        if CommandLine.arguments.contains("--integration-test") {
            #if DEBUG
                do {
                    guard !smoke else { throw MCPHTTPParseError(reason: L10n.text("集成测试与 startup-smoke 不能同时启用")) }
                    let context = try IntegrationTestContext(environment: ProcessInfo.processInfo.environment)
                    _model = StateObject(wrappedValue: ConsoleViewModel(
                        stores: context.stores, startsMIDI: false,
                        mcpCredentials: context.credentials, integrationTest: true,
                        // Native acceptance scripts exercise the arm example's parameters and safety gate.
                        initialPreset: .robotArm,
                        providerConfiguration: providerConfiguration
                    ))
                    return
                } catch {
                    FileHandle.standardError
                        .write(Data((L10n.text("隔离测试启动失败：") + error.localizedDescription + "\n").utf8))
                    Darwin.exit(2)
                }
            #else
                FileHandle.standardError.write(Data(L10n.text("隔离测试仅支持 Debug 构建。\n").utf8))
                Darwin.exit(2)
            #endif
        }
        _model = StateObject(wrappedValue: ConsoleViewModel(
            stores: smoke ? .temporary() : .standard,
            startsMIDI: !smoke,
            mcpCredentials: pipedCredentials,
            providerConfiguration: providerConfiguration
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    #if DEBUG
                        appDelegate.snapshotModel = model
                    #endif
                }
                .environment(\.locale, Locale(identifier: L10n.language.rawValue))
                .frame(minWidth: 1_200, minHeight: 760)
                .background(WindowTitlebar().frame(width: 0, height: 0))
        }
        .defaultSize(width: 1_260, height: 920)
        .windowStyle(.hiddenTitleBar)

        Settings {
            TabView {
                SurfaceProgramsView(model: model).tabItem { Label(L10n.text("页面与宏"), systemImage: "square.stack") }
                FeedbackSettingsView(controller: model.feedbackSettings).tabItem { Label(
                    L10n.text("反馈调度"),
                    systemImage: "speedometer"
                ) }
                CodexAgentSettingsView(controller: model.codex).tabItem { Label("Agent", systemImage: "cpu") }
                LanguageSettingsView().tabItem { Label(L10n.text("语言"), systemImage: "globe") }
                ConfigurationLibraryView(model: model, library: model.library)
                    .tabItem { Label(L10n.text("配置库"), systemImage: "folder") }
            }
            .environment(\.locale, Locale(identifier: L10n.language.rawValue))
        }
    }
}

#if DEBUG
    @MainActor
    func renderNativeUISnapshots(model: ConsoleViewModel, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previews: [(String, AnyView, CGSize)] = [
            ("approval", AnyView(CodexApprovalReviewView(controller: model.codex, approval: .init(
                id: .number(101), slotID: AgentSlotID(1),
                detail: "swift test --build-path build/swiftpm\n/offline-fixture/workspace\nReview the requested test execution before deciding.",
                threadID: "preview-thread", turnID: "preview-turn"
            ))), CGSize(width: 660, height: 460)),
            ("mcp", AnyView(MCPSettingsView(controller: model.mcp)), CGSize(width: 700, height: 720)),
            ("output", AnyView(OutputSettingsView(controller: model.output)), CGSize(width: 880, height: 720)),
            ("console", AnyView(ContentView(model: model)), CGSize(width: 1200, height: 760)),
            ("agents", AnyView(CodexAgentSettingsView(controller: model.codex)), CGSize(width: 680, height: 660)),
            ("programs", AnyView(SurfaceProgramsView(model: model)), CGSize(width: 700, height: 580)),
            (
                "feedback",
                AnyView(FeedbackSettingsView(controller: model.feedbackSettings)),
                CGSize(width: 560, height: 350)
            ),
            ("language", AnyView(LanguageSettingsView()), CGSize(width: 480, height: 240)),
            (
                "library",
                AnyView(ConfigurationLibraryView(model: model, library: model.library)),
                CGSize(width: 560, height: 360)
            )
        ]
        for (name, content, size) in previews {
            let hosting = NSHostingView(rootView: content.environment(
                \.locale,
                Locale(identifier: L10n.language.rawValue)
            ))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            window.setContentSize(size)
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(120))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: directory.appending(path: "\(name).png"))
            window.orderOut(nil)
        }
    }
#endif
