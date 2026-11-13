import BCRAgentCore
import SwiftUI

/// Runtime preferences update the existing view graph without replacing any device/Agent session.
struct LanguageSettingsView: View {
    @ObservedObject var settings: LanguageSettings

    init(settings: LanguageSettings = .shared) { self.settings = settings }

    var body: some View {
        Form {
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
                Text(L10n.text("应用界面立即切换并自动保存；系统菜单、文件面板和系统对话框按钮需重启应用后切换。"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L10n.text("界面语言"))
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 480, height: 260)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
