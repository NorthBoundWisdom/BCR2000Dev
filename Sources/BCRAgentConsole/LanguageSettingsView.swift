import BCRAgentCore
import SwiftUI

/// Preferences take effect on relaunch so changing language never interrupts a device/Agent session.
struct LanguageSettingsView: View {
    @AppStorage(AppLanguage.preferenceKey) private var selection = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker(L10n.text("语言"), selection: Binding(
                    get: { AppLanguage(rawValue: selection) ?? .system },
                    set: { $0.save(); selection = $0.rawValue }
                )) {
                    Text(L10n.text("跟随系统")).tag(AppLanguage.system)
                    Text(verbatim: "简体中文").tag(AppLanguage.chinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                .accessibilityIdentifier("app-language")
                Text(L10n.text("当前语言：\(L10n.language == .chinese ? "简体中文" : "English")"))
                    .foregroundStyle(.secondary)
                Text(L10n.text("语言更改将在下次启动时生效。请关闭并重新打开应用。"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L10n.text("界面语言"))
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 480, height: 240)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
