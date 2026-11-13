import BCRAgentCore
import SwiftUI

/// Every setting lives in the one Settings window; status chips only jump to their page.
enum SettingsTab: String, CaseIterable, Identifiable {
    case device, output, mcp, agent, programs, feedback, library, language

    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: L10n.text("设备")
        case .output: L10n.text("输出")
        case .mcp: "MCP"
        case .agent: "Agent"
        case .programs: L10n.text("页面与宏")
        case .feedback: L10n.text("反馈调度")
        case .library: L10n.text("配置库")
        case .language: L10n.text("语言")
        }
    }

    var icon: String {
        switch self {
        case .device: "cable.connector"
        case .output: "arrow.up.forward.circle"
        case .mcp: "network"
        case .agent: "cpu"
        case .programs: "square.stack"
        case .feedback: "speedometer"
        case .library: "folder"
        case .language: "globe"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .device
}

enum SettingsLayout {
    /// One size for every page, so switching pages never resizes the window.
    static let size = CGSize(width: 880, height: 720)
}

extension View {
    /// Pages fill the fixed Settings window instead of declaring their own size.
    func settingsPage() -> some View {
        // Grouped forms and lists share the page background instead of their own grey slab.
        scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background)
            .preferredColorScheme(.dark)
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: ConsoleViewModel
    @ObservedObject var language: LanguageSettings
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
                    .tag(tab)
            }
        }
        .frame(width: SettingsLayout.size.width, height: SettingsLayout.size.height)
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .device: MIDIEndpointSettingsView(model: model)
        case .output: OutputSettingsView(controller: model.output)
        case .mcp: MCPSettingsView(controller: model.mcp)
        case .agent: CodexAgentSettingsView(controller: model.codex, model: model)
        case .programs: SurfaceProgramsView(model: model)
        case .feedback: FeedbackSettingsView(controller: model.feedbackSettings)
        case .library: ConfigurationLibraryView(model: model, library: model.library)
        case .language: LanguageSettingsView(settings: language)
        }
    }
}

/// A top-bar status chip that opens the Settings window on its own page.
struct SettingsChipButton<Label: View>: View {
    let tab: SettingsTab
    @ViewBuilder var label: () -> Label
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            SettingsNavigation.shared.tab = tab
            openSettings()
        } label: { label() }
            .buttonStyle(.plain)
    }
}
