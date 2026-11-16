import BCRFoundation
import BCRSurfaceDomain
import SwiftUI

struct ParameterScenesView: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var name = ""
    @State private var renaming: ParameterScene?
    @State private var rename = ""
    @State private var overwriting: String?
    @State private var deleting: ParameterScene?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("场景")).font(.subheadline.bold())
            Text(L10n.text("保存参数值；调用后灯环正常刷新，外部输出仍受安全门限制。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.configuration.scenes ?? []) { scene in
                HStack {
                    if renaming?.id == scene.id {
                        TextField(L10n.text("场景名称"), text: $rename)
                            .accessibilityIdentifier("scenes.renameName")
                        Button(L10n.text("重命名")) { model.renameScene(scene.id, to: rename); renaming = nil }
                            .accessibilityIdentifier("parameter.scenes.rename.commit.\(scene.id)")
                            .disabled(rename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(L10n.text("取消")) { renaming = nil }
                            .accessibilityIdentifier("parameter.scenes.cancel.\(scene.id)")
                    } else {
                        Text(scene.name).lineLimit(1)
                        Text(L10n.text("\(scene.values.count) 个数值")).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(L10n.text("调用")) { model.recallScene(scene.id) }
                            .accessibilityIdentifier("scenes.recall.\(scene.id)")
                        Menu {
                            Button(L10n.text("覆盖为当前值…")) { overwriting = scene.name }
                                .accessibilityIdentifier(
                                    "parameter.scenes.replace.with.current.values.begin.\(scene.id)"
                                )
                            Button(L10n.text("重命名")) { renaming = scene; rename = scene.name }
                                .accessibilityIdentifier("parameter.scenes.rename.\(scene.id)")
                            Button(L10n.text("删除"), role: .destructive) { deleting = scene }
                                .accessibilityIdentifier("parameter.scenes.delete.\(scene.id)")
                        } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityIdentifier("parameter.scenes.replace.with.current.values.\(scene.id)")
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel(L10n.text("场景操作"))
                    }
                }
            }
            HStack {
                TextField(L10n.text("场景名称"), text: $name)
                    .accessibilityIdentifier("scenes.name")
                Button(L10n.text("保存当前值")) {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if model.configuration.scenes?.contains(where: { $0.name == trimmed }) == true {
                        overwriting = trimmed
                    } else { model.captureScene(name: trimmed); name = "" }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("scenes.capture")
            }
        }
        .controlSize(.small)
        .insetCard()
        .confirmationDialog(L10n.text("覆盖场景的已保存数值？"), isPresented: Binding(
            get: { overwriting != nil }, set: { if !$0 { overwriting = nil } }
        )) {
            Button(L10n.text("覆盖"), role: .destructive) {
                if let overwriting { model.captureScene(name: overwriting, overwrite: true) }
                overwriting = nil; name = ""
            }.accessibilityIdentifier("parameter.scenes.overwrite.saved.scene.values.overwrite")
            Button(L10n.text("取消"), role: .cancel) { overwriting = nil }
                .accessibilityIdentifier("parameter.scenes.overwrite.saved.scene.values.cancel")
        }
        .confirmationDialog(L10n.text("删除场景？"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button(L10n.text("删除"), role: .destructive) {
                if let deleting { model.deleteScene(deleting.id) }; deleting = nil
            }.accessibilityIdentifier("parameter.scenes.delete.scene.delete")
            Button(L10n.text("取消"), role: .cancel) { deleting = nil }
                .accessibilityIdentifier("parameter.scenes.delete.scene.cancel")
        }
    }
}
