import BCRAgentCore
import SwiftUI

/// Every setting lives in the one Settings window; status chips only jump to their page.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, device, output, mcp, agent, programs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.text("通用")
        case .device: L10n.text("设备")
        case .output: L10n.text("输出")
        case .mcp: "MCP"
        case .agent: "Agent"
        case .programs: L10n.text("页面与宏")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .device: "cable.connector"
        case .output: "arrow.up.forward.circle"
        case .mcp: "network"
        case .agent: "cpu"
        case .programs: "square.stack"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
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
        case .general: GeneralSettingsView(model: model, language: language)
        case .device: DeviceSettingsView(model: model)
        case .output: OutputSettingsView(controller: model.output)
        case .mcp: MCPSettingsView(controller: model.mcp)
        case .agent: CodexAgentSettingsView(controller: model.codex, model: model)
        case .programs: SurfaceProgramsView(model: model)
        }
    }
}

/// Inline state beside an Apply button. Drafts live in the page, so the dirty hint also says that
/// leaving the page drops them; a successful apply shows a short confirmation.
struct ApplyStatusLabel: View {
    let dirty: Bool
    /// Incremented by the page after each successful apply.
    let applied: Int
    var confirmation = L10n.text("已应用")
    @State private var showsApplied = false

    var body: some View {
        Group {
            if dirty {
                Label(L10n.text("有未应用的修改；切换页面或关闭窗口会丢弃"), systemImage: "pencil.circle")
                    .foregroundStyle(.orange)
            } else if showsApplied {
                Label(confirmation, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .font(.caption)
        .accessibilityIdentifier("settings.applyStatus")
        .task(id: applied) {
            guard applied > 0 else { return }
            showsApplied = true
            try? await Task.sleep(for: .seconds(2))
            showsApplied = false
        }
    }
}

/// A caption for a control that takes effect immediately on a page that otherwise uses Apply.
struct ImmediateEffectNote: View {
    var body: some View {
        Text(L10n.text("即时生效，不需要“应用”")).font(.caption).foregroundStyle(.secondary)
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
