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

private struct MacroActionDraft: Identifiable {
    let id = UUID()
    enum Kind: String, CaseIterable { case set, step, toggle }
    var kind: Kind = .set
    var parameter: ParameterID
    var value: Double = 0
}

struct SurfaceProgramsView: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var pageName = ""
    @State private var macroName = ""
    @State private var actions: [MacroActionDraft] = []
    @State private var deletingPage: AssignmentPage?
    @State private var deletingMacro: SurfaceMacro?
    @State private var error: String?

    var body: some View {
        Form {
            Section(L10n.text("页面与层")) {
                Picker(L10n.text("当前页面"), selection: Binding(
                    get: { model.configuration.activePageID ?? SurfaceConfiguration.basePageID },
                    set: { id in perform { try model.selectPage(id) } }
                )) {
                    Text(L10n.text("基础页面")).tag(SurfaceConfiguration.basePageID)
                    ForEach(model.configuration.pages) { Text($0.name).tag($0.id) }
                }
                if let warning = model.configuration.pageNavigationWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    TextField(L10n.text("页面名称"), text: $pageName)
                    Button(L10n.text("复制当前分配为新页面")) {
                        perform {
                            var next = model.configuration
                            try next.addPage(.init(name: pageName, assignments: next.assignments))
                            try model.updatePrograms(next)
                            pageName = ""
                        }
                    }
                }
                ForEach(model.configuration.pages) { page in
                    HStack {
                        Text(page.name); Spacer(); Button(L10n.text("删除"), role: .destructive) { deletingPage = page }
                    }
                }
            }
            Section(L10n.text("宏")) {
                TextField(L10n.text("宏名称"), text: $macroName)
                ForEach($actions) { $action in
                    HStack {
                        Picker(L10n.text("参数"), selection: $action.parameter) {
                            ForEach(model.configuration.parameters) {
                                Text(BuiltInNamePresentation.displayName($0.name)).tag($0.id)
                            }
                        }
                        Picker(L10n.text("动作"), selection: $action.kind) {
                            Text(L10n.text("设为指定值")).tag(MacroActionDraft.Kind.set)
                            Text(L10n.text("步进")).tag(MacroActionDraft.Kind.step)
                            Text(L10n.text("切换")).tag(MacroActionDraft.Kind.toggle)
                        }
                        .accessibilityIdentifier("macros.action.kind.\(action.id)")
                        if action.kind != .toggle {
                            TextField(L10n.text("值"), value: $action.value, format: .number).frame(width: 90)
                        }
                        Button { actions.removeAll { $0.id == action.id } } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel(L10n.text("删除操作"))
                    }
                }
                HStack {
                    Button(L10n.text("添加操作")) {
                        if let first = model.configuration.parameters.first {
                            actions.append(.init(parameter: first.id, value: first.defaultValue))
                        }
                    }.disabled(actions.count >= 64 || model.configuration.parameters.isEmpty)
                    Button(L10n.text("保存宏")) {
                        perform {
                            var next = model.configuration
                            let mutations = actions.map { action -> ParameterMutation in
                                switch action.kind {
                                case .set: .set(action.parameter, action.value)
                                case .step: .step(action.parameter, action.value)
                                case .toggle: .toggle(action.parameter)
                                }
                            }
                            try next.addMacro(.init(name: macroName, actions: mutations))
                            try model.updatePrograms(next)
                            actions = []; macroName = ""
                        }
                    }
                }
                ForEach(model.configuration.macros) { macro in
                    HStack {
                        Text("\(macro.name) · \(macro.actions.count)")
                        Spacer()
                        Button(L10n.text("运行")) { model.runMacro(macro.id) }
                            .accessibilityIdentifier("macros.run.\(macro.id)")
                        Button(L10n.text("删除"), role: .destructive) { deletingMacro = macro }
                    }
                }
                Text(L10n.text("从检查器将页面或宏分配给按键。页面共享参数值；宏按顺序执行，最多 64 项。"))
                    .font(.caption)
            }
            if let execution = model.engine.lastMacroExecution {
                Section(L10n.text("最近宏执行结果")) {
                    MacroExecutionResultsView(execution: execution)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped).padding(12).settingsPage()
        .confirmationDialog(L10n.text("删除页面及其切换绑定？"), isPresented: Binding(
            get: { deletingPage != nil }, set: { if !$0 { deletingPage = nil } }
        )) {
            Button(L10n.text("删除"), role: .destructive) {
                perform {
                    if let page = deletingPage {
                        var next = model.configuration; next.deletePage(page.id); try model.updatePrograms(next)
                    }
                }
                deletingPage = nil
            }
            Button(L10n.text("取消"), role: .cancel) { deletingPage = nil }
        }
        .confirmationDialog(L10n.text("删除宏及其按键绑定？"), isPresented: Binding(
            get: { deletingMacro != nil }, set: { if !$0 { deletingMacro = nil } }
        )) {
            Button(L10n.text("删除"), role: .destructive) {
                perform {
                    if let macro = deletingMacro {
                        var next = model.configuration; next.deleteMacro(macro.id); try model.updatePrograms(next)
                    }
                }
                deletingMacro = nil
            }
            Button(L10n.text("取消"), role: .cancel) { deletingMacro = nil }
        }
        .preferredColorScheme(.dark)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}
