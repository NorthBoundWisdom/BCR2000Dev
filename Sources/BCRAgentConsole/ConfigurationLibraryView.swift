import BCRAgentCore
import SwiftUI

struct ConfigurationLibraryView: View {
    @ObservedObject var model: ConsoleViewModel
    @ObservedObject var library: ConfigurationLibrary
    @State private var name = ""
    @State private var loading: SavedConfiguration?
    @State private var deleting: SavedConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L10n.text("配置名称"), text: $name)
                Button(L10n.text("保存当前配置")) {
                    if library.save(name: name, configuration: model.configuration) { name = "" }
                }
            }
            if let error = library.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            List(library.entries) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    Button(L10n.text("载入")) { loading = entry }
                    Button(L10n.text("删除"), role: .destructive) { deleting = entry }
                }
            }
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
                    if let entry = deleting { library.delete(entry.id) }
                    deleting = nil
                }
                Button(L10n.text("取消"), role: .cancel) { deleting = nil }
            }
        }
        .padding(20)
        .settingsPage()
    }
}
