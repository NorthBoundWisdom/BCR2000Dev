import BCRAgentCore
import SwiftUI

struct WorkspaceTabsView: View {
    @ObservedObject var model: ConsoleViewModel
    @ObservedObject var output: OutputController
    @State private var selection: WorkspaceTab = .parameters

    init(model: ConsoleViewModel) {
        self.model = model
        output = model.output
    }

    var body: some View {
        let outputActive = output.settings.enabled
        let tabs = model.workspacePanels.visibleTabs(outputActive: outputActive)
        let tab = model.workspacePanels.resolved(selection, outputActive: outputActive)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker(L10n.text("工作区"), selection: Binding(get: { tab }, set: { selection = $0 })) {
                    ForEach(tabs) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
                Spacer(minLength: 0)
                panelMenu(outputActive: outputActive)
            }

            switch tab {
            case .parameters: ParameterListView(model: model)
            case .arm: ArmPreviewView(model: model)
            case .agents: AgentGridView(model: model)
            case .monitor: MIDIMonitorView(model: model)
            case .output: OutputReadoutView(model: model, controller: model.output)
            }
        }
        .panelStyle()
    }

    private func panelMenu(outputActive: Bool) -> some View {
        Menu {
            Section(L10n.text("专业面板")) {
                ForEach(WorkspaceTab.optional) { panel in
                    Toggle(isOn: Binding(
                        get: { model.workspacePanels.isEnabled(panel) },
                        set: { isOn in
                            if model.setWorkspacePanel(panel, enabled: isOn), isOn { selection = panel }
                        }
                    )) {
                        Label(panel.title, systemImage: panel.systemImage)
                        if let summary = panel.optionalSummary { Text(summary) }
                    }
                }
            }
            if outputActive, !model.workspacePanels.isEnabled(.output) {
                Text(L10n.text("输出运行期间始终显示“输出”面板"))
            }
        } label: {
            Label(L10n.text("面板"), systemImage: "rectangle.stack.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .accessibilityLabel(L10n.text("专业面板"))
        .accessibilityIdentifier("workspace.panels")
        .help(L10n.text("启用或隐藏机械臂预览、输出等专业面板"))
    }
}

// MARK: - Parameters

private struct ParameterListView: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var pendingPreset: ConfigurationPreset?
    @State private var confirmsImport = false
    @State private var pendingImport: SurfaceConfiguration?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("软件参数是唯一事实来源：拖动滑块会回写所有绑定控件，转动控件也会移动这里的滑块。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            // One row when it fits; otherwise two aligned rows instead of ragged grid cells.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { createButton; Spacer(minLength: 8); importButton; exportButton; presetMenu }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { createButton; presetMenu }
                    HStack(spacing: 8) { importButton; exportButton }
                }
            }
            .controlSize(.small)
            .confirmationDialog(L10n.text("替换当前全部参数与分配？"), isPresented: $confirmsImport) {
                Button(L10n.text("导入并替换"), role: .destructive) {
                    if let pendingImport { model.installConfiguration(pendingImport) }
                    pendingImport = nil
                }
                Button(L10n.text("取消"), role: .cancel) { pendingImport = nil }
            } message: {
                if let pendingImport {
                    Text(
                        L10n
                            .text(
                                "“\(BuiltInNamePresentation.displayName(pendingImport.name))”包含 \(pendingImport.parameters.count) 个参数、\(pendingImport.assignments.count) 项分配；实体映射保留。"
                            )
                    )
                }
            }
            .confirmationDialog(
                L10n.text("载入“\(pendingPreset?.title ?? "")”？"),
                isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
                presenting: pendingPreset
            ) { preset in
                Button(L10n.text("载入并替换"), role: .destructive) { model.loadPreset(preset) }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: { preset in
                Text(L10n.text("\(preset.summary)。会替换当前全部参数与功能分配；实体硬件映射不受影响。"))
            }

            ForEach(model.configuration.parameterGroups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(group.isEmpty ? L10n.text("未分组") : BuiltInNamePresentation.displayName(group))
                            .font(.subheadline.bold())
                        Spacer()
                        Button(L10n.text("复位到默认")) { model.resetGroup(group) }
                            .controlSize(.small)
                    }
                    ForEach(model.configuration.parameters.filter { $0.group == group }) { definition in
                        ParameterRow(model: model, definition: definition)
                    }
                }
                .insetCard()
            }
        }
    }

    private var createButton: some View {
        Button {
            model.createParameter()
        } label: {
            Label(L10n.text("新建参数"), systemImage: "plus")
        }
    }

    private var importButton: some View {
        Button(L10n.text("导入配置…")) {
            Task {
                pendingImport = await model.chooseConfigurationImport()
                confirmsImport = pendingImport != nil
            }
        }
        .accessibilityLabel(L10n.text("导入配置"))
        .accessibilityIdentifier("configuration.import")
        .help(L10n.text("导入参数与功能分配，确认后替换当前配置"))
    }

    private var exportButton: some View {
        Button(L10n.text("导出配置…")) { Task { await model.chooseConfigurationExport() } }
            .accessibilityLabel(L10n.text("导出配置"))
            .accessibilityIdentifier("configuration.export")
            .help(L10n.text("导出参数与功能分配，不包含实体映射"))
    }

    private var presetMenu: some View {
        Menu(L10n.text("载入预置…")) {
            ForEach(ConfigurationPreset.allCases) { preset in
                Button {
                    pendingPreset = preset
                } label: {
                    Text(preset.title)
                    Text(preset.summary)
                }
            }
        }
        .fixedSize()
        .accessibilityLabel(L10n.text("载入预置配置"))
        .accessibilityIdentifier("configuration.preset")
        .help(L10n.text("用内置的默认配置或示例替换当前配置"))
    }
}

private struct ParameterRow: View {
    @ObservedObject var model: ConsoleViewModel
    let definition: ParameterDefinition

    var body: some View {
        // One line when there is room for a usable slider, otherwise slider on its own line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                name.frame(width: 120, alignment: .leading)
                control.frame(minWidth: 160)
                valueText.frame(width: 80, alignment: .trailing)
                chips.frame(width: 130, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    name
                    Spacer(minLength: 4)
                    valueText
                    chips
                }
                control
            }
        }
    }

    private var value: Double {
        model.engine.value(of: definition.id) ?? definition.defaultValue
    }

    private var name: some View {
        Text(BuiltInNamePresentation.displayName(definition.name)).lineLimit(1)
    }

    private var valueText: some View {
        Text(definition.formatted(value, minimumFractionDigits: model.parameterFractionDigits(definition.id)))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Theme.parameter)
            .lineLimit(1)
    }

    @ViewBuilder
    private var control: some View {
        if definition.kind == .toggle {
            HStack {
                Toggle("", isOn: Binding(
                    get: { value >= definition.midpoint },
                    set: { model.setParameter(definition.id, to: $0 ? definition.maximum : definition.minimum) }
                ))
                .labelsHidden()
                Spacer(minLength: 0)
            }
        } else {
            Slider(
                value: Binding(get: { value }, set: { model.setParameter(definition.id, to: $0) }),
                in: definition.minimum ... definition.maximum
            )
        }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            let controls = model.configuration.controls(targetingParameter: definition.id)
            if controls.isEmpty {
                Text(L10n.text("未绑定")).font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(controls) { control in
                Button(control.shortName) {
                    model.selectedControl = control
                    if control.section == .pushEncoder || control.section == .pushEncoderButton {
                        model.selectGroup(control.row)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption2.monospaced().bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.selection.opacity(model.selectedControl == control ? 0.35 : 0.14), in: Capsule())
            }
        }
    }
}

// MARK: - Agents

private struct AgentGridView: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentBackendStatusView(controller: model.codex)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                ForEach(model.slots) { slot in
                    let controls = model.configuration.controls(targeting: .agentPrimaryAction(slot.id))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(slot.name).font(.headline)
                            Spacer()
                            Circle()
                                .fill(stateColor(slot.state))
                                .frame(width: 9, height: 9)
                                .shadow(color: stateColor(slot.state), radius: 4)
                        }
                        Text(slot.state.displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(stateColor(slot.state))
                        ProgressView(value: slot.progress).tint(stateColor(slot.state))
                        Text(slot.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack {
                            Button(slot.state == .waitingApproval && model.codex.backend == .codex ? L10n
                                .text("查看审批") : primaryActionTitle(slot.state)) { model.performPrimaryAction(slot.id) }
                                .buttonStyle(.borderedProminent)
                                .tint(stateColor(slot.state))
                            if slot.state == .waitingApproval {
                                Button(L10n.text("拒绝")) { model.decline(slot.id) }
                                if model.codex.backend == .codex {
                                    Button(L10n.text("中断")) { model.interrupt(slot.id) }
                                }
                            }
                            Spacer()
                            Text(controls.isEmpty ? L10n.text("未绑定") : controls.map(\.shortName).joined(separator: " "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .controlSize(.small)
                    }
                    .insetCard(padding: 11)
                }
            }
        }
    }
}

// MARK: - MIDI monitor

private struct MIDIMonitorView: View {
    @ObservedObject var model: ConsoleViewModel

    private static let timeFormat = Date.FormatStyle()
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)
        .secondFraction(.fractional(3))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("IN = 设备 → 软件，OUT = 软件 → 设备。灰色为 Mock 模式下收到但未处理的实体输入。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("清空")) { model.clearMonitor() }
                    .controlSize(.small)
            }
            if model.events.isEmpty {
                Text(L10n.text("还没有 MIDI 事件。"))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.events.suffix(40).reversed()) { event in
                        HStack(spacing: 10) {
                            Text(event.time, format: Self.timeFormat)
                                .foregroundStyle(.tertiary)
                            Text(event.direction == .input ? "IN " : "OUT")
                                .foregroundStyle(event.direction == .input ? Theme.parameter : Theme.selection)
                                .bold()
                            Text(event
                                .origin == .agent ? "AGENT" :
                                (event.origin == .external ? "STATE" : (event.source == .mock ? "MOCK" : "HW  ")))
                                .foregroundStyle(.secondary)
                            if let delivery = event.delivery {
                                Text(delivery == .sent ? L10n
                                    .text("已送达") : (delivery == .failed ? L10n.text("发送失败") : L10n.text("未连接丢弃")))
                                    .foregroundStyle(delivery == .sent ? Color.secondary : Color.orange)
                            }
                            Text(event.message.diagnosticDescription)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Spacer(minLength: 4)
                            Text(event.control?.shortName ?? L10n.text("未映射"))
                                .foregroundStyle(event.control == nil ? .orange : .secondary)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .opacity(event.ignored ? 0.45 : 1)
                    }
                }
            }
        }
    }
}
