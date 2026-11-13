import BCRAgentCore
import SwiftUI

/// General settings: interface language and the saved-configuration library. Both are small, so
/// they share one page instead of leaving two mostly empty pages in the fixed-size window.
struct GeneralSettingsView: View {
    @ObservedObject var model: ConsoleViewModel
    @ObservedObject var language: LanguageSettings
    @State private var loading: SavedConfiguration?
    @State private var deleting: SavedConfiguration?

    init(model: ConsoleViewModel, language: LanguageSettings = .shared) {
        self.model = model; self.language = language
    }

    var body: some View {
        Form {
            LanguageSettingsSection(settings: language)
            ConfigurationLibrarySection(model: model, library: model.library, loading: $loading, deleting: $deleting)
        }
        .formStyle(.grouped)
        // Presented from the page, not from a row inside the form, which leaves a hidden helper window.
        .confirmationDialog(L10n.text("替换当前全部参数与分配？"), isPresented: Binding(
            get: { loading != nil }, set: { if !$0 { loading = nil } }
        )) {
            Button(L10n.text("载入并替换"), role: .destructive) {
                if let entry = loading { _ = model.installConfiguration(entry.configuration) }
                loading = nil
            }
            Button(L10n.text("取消"), role: .cancel) { loading = nil }
        }
        .confirmationDialog(L10n.text("删除保存的配置？"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button(L10n.text("删除"), role: .destructive) {
                if let entry = deleting { model.library.delete(entry.id) }
                deleting = nil
            }
            Button(L10n.text("取消"), role: .cancel) { deleting = nil }
        }
        .padding(12)
        .settingsPage()
    }
}

/// Runtime preferences update the existing view graph without replacing any device/Agent session.
struct LanguageSettingsSection: View {
    @ObservedObject var settings: LanguageSettings

    var body: some View {
        Section {
            Picker(L10n.text("语言"), selection: $settings.selection) {
                Text(L10n.text("跟随系统")).tag(AppLanguage.system)
                Text(verbatim: "简体中文").tag(AppLanguage.chinese)
                Text(verbatim: "English").tag(AppLanguage.english)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("app-language")
            Text(L10n.text("当前语言：\(L10n.language == .chinese ? "简体中文" : "English")"))
                .foregroundStyle(.secondary)
            Text(L10n.text("应用界面立即切换并自动保存；系统菜单、文件面板、系统对话框按钮及 macOS 系统错误描述需重启应用后切换。"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(L10n.text("界面语言"))
        }
    }
}
