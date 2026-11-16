import BCRFoundation
import BCRCodexAdapter
import BCRSurfaceDomain
import BCRExamples
import BCRConfigurationAdapter
import BCRMCPAdapter
import BCRHTTPTransport
import BCRCoreMIDIDriver
import BCRPersistenceAdapter
import SwiftUI

/// Named snapshots of the parameter/assignment configuration (never the hardware map).
struct ConfigurationLibrarySection: View {
    @ObservedObject var model: ConsoleViewModel
    @ObservedObject var library: ConfigurationLibrary
    /// Confirmations are presented by the page so they never live inside a form row.
    @Binding var loading: SavedConfiguration?
    @Binding var deleting: SavedConfiguration?
    @State private var name = ""

    var body: some View {
        Section {
            HStack {
                TextField(L10n.text("配置名称"), text: $name, prompt: Text(L10n.text("输入名称后保存")))
                    .accessibilityIdentifier("configuration.library.configuration.name")
                Button(L10n.text("保存当前配置")) {
                    if library.save(name: name, configuration: model.configuration) { name = "" }
                }.accessibilityIdentifier("configuration.library.save.current.configuration")
            }
            if let error = library.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if library.entries.isEmpty {
                Text(L10n.text("还没有保存的配置。保存后可在这里载入或删除。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(library.entries) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    Button(L10n.text("载入")) { loading = entry }
                        .accessibilityIdentifier("configuration.library.load.\(entry.id)")
                    Button(L10n.text("删除"), role: .destructive) { deleting = entry }
                        .accessibilityIdentifier("configuration.library.delete.\(entry.id)")
                }
            }
            Text(L10n.text("保存参数、分配、页面与宏，不含硬件映射；载入前确认，会替换当前全部参数与分配。"))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(L10n.text("配置库"))
        }
    }
}
