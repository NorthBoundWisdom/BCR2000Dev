import BCRAgentCore
import SwiftUI

struct ControlInspectorView: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var confirmsMapReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let control = model.selectedControl {
                    header(control)
                    bindingSection(control)
                    FunctionSection(model: model, control: control).id(control)
                    if let id = model.configuration.assignment(for: control)?.target.parameterID,
                       let definition = model.configuration.parameter(id) {
                        ParameterEditor(model: model, definition: definition)
                            .id(definition.id)
                    }
                } else {
                    Text("在左侧面板选择一个控件")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                BulkAssignmentSection(model: model)
            }
            .padding(14)
        }
        .background(Color.black.opacity(0.18))
    }

    private func header(_ control: BCRControlID) -> some View {
        let state = model.engine.state(of: control)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(control.shortName)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                Text(control.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 14) {
                valueBadge("面板", "\(model.displayValue(of: control))", color: .primary)
                valueBadge("IN", state.lastInput.map(String.init) ?? "—", color: Theme.parameter)
                valueBadge("OUT", state.lastOutput.map(String.init) ?? "—", color: Theme.selection)
                valueBadge("事件", "\(state.eventCount)", color: .secondary)
            }
        }
        .panelStyle()
    }

    private func valueBadge(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced).bold()).foregroundStyle(color)
        }
    }

    private func bindingSection(_ control: BCRControlID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("硬件绑定", icon: "cable.connector")
            if let midi = model.engine.hardwareMap.midi(for: control) {
                Label(midi.description, systemImage: "checkmark.circle.fill")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)
            } else {
                Label("未学习", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            }

            switch model.source {
            case .mock:
                Text("Mock 设备使用自带预设（全部为通道 1 的 CC），不需要学习。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .hardware:
                HStack {
                    if model.isLearning {
                        Button("停止学习") { model.stopLearning() }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                    } else {
                        Button("从这里开始学习") { model.beginLearning(at: control) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("清除绑定") { model.unbind(control) }
                        .disabled(model.engine.hardwareMap.midi(for: control) == nil)
                }
                Text("学习时请操作实体控件：编码器转动、按键按下。完成后自动跳到本区下一个未学习控件。已学习 \(model.learnedCount) / \(BCRLayout.allControls.count)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("清空全部实体映射…", role: .destructive) { confirmsMapReset = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(model.learnedCount == 0)
                    .confirmationDialog("清空全部实体映射？", isPresented: $confirmsMapReset) {
                        Button("清空", role: .destructive) { model.resetHardwareMap() }
                    } message: {
                        Text("功能分配会保留，只删除学到的 MIDI 身份。")
                    }
            }
        }
        .panelStyle()
    }
}

// MARK: - Function

private enum TargetKind: String, CaseIterable, Identifiable {
    case none, parameter, agent, reset, step, preset, cycle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "未分配"
        case .parameter: "参数"
        case .agent: "Agent 主操作"
        case .reset: "复位参数组"
        case .step: "参数步进"
        case .preset: "设为指定值"
        case .cycle: "循环预设值"
        }
    }

    init(_ target: ControlTarget?) {
        switch target {
        case nil: self = .none
        case .parameter?: self = .parameter
        case .agentPrimaryAction?: self = .agent
        case .resetGroup?: self = .reset
        case .stepParameter?: self = .step
        case .setParameter?: self = .preset
        case .cycleParameter?: self = .cycle
        }
    }
}

private struct FunctionSection: View {
    @ObservedObject var model: ConsoleViewModel
    let control: BCRControlID

    private var assignment: ControlAssignment? {
        model.configuration.assignment(for: control)
    }

    private var availableKinds: [TargetKind] {
        control.isContinuous ? [.none, .parameter] : TargetKind.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("功能", icon: "slider.horizontal.3")

            Picker("类型", selection: kindBinding) {
                ForEach(availableKinds) { Text($0.title).tag($0) }
            }

            switch assignment?.target {
            case let .parameter(id)?:
                HStack {
                    Picker("参数", selection: Binding(
                        get: { id },
                        set: { update(target: .parameter($0)) }
                    )) {
                        ForEach(model.configuration.parameters) { parameter in
                            Text(parameter.group.isEmpty ? parameter.name : "\(parameter.group) · \(parameter.name)")
                                .tag(parameter.id)
                        }
                    }
                    Button {
                        model.createParameter(assigningTo: control)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("新建参数并分配给此控件")
                }
                if !control.isContinuous {
                    Picker("按键行为", selection: Binding(
                        get: { assignment?.buttonBehavior ?? .toggle },
                        set: { behavior in modify { $0.buttonBehavior = behavior } }
                    )) {
                        ForEach(ButtonBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("反向", isOn: Binding(
                    get: { assignment?.inverted ?? false },
                    set: { inverted in modify { $0.inverted = inverted } }
                ))
                let shared = model.configuration.controls(targetingParameter: id).filter { $0 != control }
                if !shared.isEmpty {
                    Text("同一参数也绑定在：\(shared.map(\.shortName).joined(separator: "、"))，会互相同步。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case let .agentPrimaryAction(slot)?:
                Picker("槽位", selection: Binding(
                    get: { slot.rawValue },
                    set: { update(target: .agentPrimaryAction(AgentSlotID($0))) }
                )) {
                    ForEach(1...8, id: \.self) { Text("Agent \($0)").tag($0) }
                }
                Text("空闲时启动、运行时中断、等待批准时批准；LED 亮度表示 Agent 状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .stepParameter?, .setParameter?, .cycleParameter?:
                if let target = assignment?.target {
                    TriggerParameterEditor(model: model, control: control, target: target)
                }

            case let .resetGroup(group)?:
                Picker("参数组", selection: Binding(
                    get: { group },
                    set: { update(target: .resetGroup($0)) }
                )) {
                    ForEach(model.configuration.parameterGroups, id: \.self) { Text($0.isEmpty ? "（未分组）" : $0).tag($0) }
                }
                Text("按下时把该组全部参数恢复为默认值，并回写所有绑定控件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case nil:
                Text(control.isContinuous
                    ? "未分配的编码器仍会显示原始值；在实体模式下拖动会直接回写灯环，便于测试。"
                    : "选择“参数”可做开关/按住，选择触发类功能可启动 Agent 或复位。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .panelStyle()
    }

    private var kindBinding: Binding<TargetKind> {
        Binding(
            get: { TargetKind(assignment?.target) },
            set: { kind in
                switch kind {
                case .none:
                    model.setAssignment(nil, for: control)
                case .parameter:
                    if let first = model.configuration.parameters.first {
                        update(target: .parameter(first.id))
                    } else {
                        model.createParameter(assigningTo: control)
                    }
                case .step, .preset, .cycle:
                    let id = assignment?.target.parameterID ?? model.configuration.parameters.first?.id ?? model.createParameter()
                    guard let id, let definition = model.configuration.parameter(id) else { return }
                    switch kind {
                    case .step: update(target: .stepParameter(id: id, step: definition.step ?? 1, wraps: false))
                    case .preset: update(target: .setParameter(id: id, value: definition.defaultValue))
                    case .cycle:
                        var seen = Set<Double>()
                        let values = [definition.minimum, definition.clamp(definition.defaultValue), definition.maximum].filter { seen.insert($0).inserted }
                        update(target: .cycleParameter(id: id, values: values))
                    default: break
                    }
                case .agent:
                    update(target: .agentPrimaryAction(AgentSlotID(1)))
                case .reset:
                    update(target: .resetGroup(model.configuration.parameterGroups.first ?? ""))
                }
            }
        )
    }

    private func update(target: ControlTarget) {
        var next = assignment ?? ControlAssignment(control: control, target: target)
        next.target = target
        model.setAssignment(next, for: control)
    }

    private func modify(_ change: (inout ControlAssignment) -> Void) {
        guard var next = assignment else { return }
        change(&next)
        model.setAssignment(next, for: control)
    }
}

// MARK: - Parameter editor

private struct ParameterEditor: View {
    @ObservedObject var model: ConsoleViewModel
    let definition: ParameterDefinition
    @State private var draftState: ParameterDraftState
    @State private var confirmsRemoval = false

    init(model: ConsoleViewModel, definition: ParameterDefinition) {
        self.model = model
        self.definition = definition
        _draftState = State(initialValue: ParameterDraftState(definition))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("参数定义", icon: "function")
                Spacer()
                Text(definition.id.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            if let value = model.engine.value(of: definition.id) {
                HStack {
                    Text(definition.formatted(value))
                        .font(.system(.title3, design: .monospaced).bold())
                        .foregroundStyle(Theme.parameter)
                        .frame(minWidth: 90, alignment: .leading)
                    if definition.kind == .toggle {
                        Toggle("", isOn: Binding(
                            get: { value >= definition.midpoint },
                            set: { model.setParameter(definition.id, to: $0 ? definition.maximum : definition.minimum) }
                        ))
                        .labelsHidden()
                    } else {
                        Slider(
                            value: Binding(get: { value }, set: { model.setParameter(definition.id, to: $0) }),
                            in: definition.minimum...definition.maximum
                        )
                    }
                }
            }

            if let conflict = draftState.conflict {
                VStack(alignment: .leading, spacing: 6) {
                    Text("参数已在其他位置修改，请处理草稿冲突。").foregroundStyle(.orange)
                    HStack {
                        Button("采用新值") { draftState.reload(conflict) }
                            .accessibilityLabel("采用新值")
                            .accessibilityIdentifier("parameter.adoptExternal")
                            .help("采用外部参数定义，放弃当前草稿")
                        Button("保留草稿") { draftState.keepDraft() }
                            .accessibilityLabel("保留草稿")
                            .accessibilityIdentifier("parameter.keepDraft")
                            .help("保留当前草稿，稍后应用将覆盖外部修改")
                    }
                    Text("保留草稿后再应用，将覆盖新定义。").foregroundStyle(.secondary)
                }
                .font(.caption)
                .controlSize(.small)
            }

            Form {
                TextField("名称", text: $draftState.value.name)
                TextField("分组", text: $draftState.value.group)
                TextField("单位", text: $draftState.value.unit)
                Picker("类型", selection: $draftState.value.kind) {
                    ForEach(ParameterKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("最小值", value: $draftState.value.minimum, format: .number)
                TextField("最大值", value: $draftState.value.maximum, format: .number)
                TextField("默认值", value: $draftState.value.defaultValue, format: .number)
                Toggle("允许 Agent 写入", isOn: $draftState.value.agentWritable)
                Toggle("启用步长吸附", isOn: Binding(
                    get: { draftState.value.step != nil },
                    set: { draftState.value.step = $0 ? (draftState.value.step ?? 1) : nil }
                ))
                if draftState.value.step != nil {
                    TextField("步长", value: Binding(
                        get: { draftState.value.step ?? 1 }, set: { draftState.value.step = $0 }
                    ), format: .number)
                }
            }
            .formStyle(.columns)
            .controlSize(.small)

            HStack {
                Button("应用修改") {
                    if let applied = model.updateParameter(draftState.value) { draftState.reload(applied) }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draftState.isDirty || draftState.conflict != nil)
                Button("还原") { draftState.reload(definition) }
                    .disabled(!draftState.isDirty && draftState.conflict == nil)
                Spacer()
                Button("删除参数…", role: .destructive) { confirmsRemoval = true }
                    .confirmationDialog("删除参数“\(definition.name)”？", isPresented: $confirmsRemoval) {
                        Button("删除", role: .destructive) { model.removeParameter(definition.id) }
                    } message: {
                        Text("所有绑定到它的控件都会变为未分配。")
                    }
            }
            .controlSize(.small)
        }
        .panelStyle()
        .onChange(of: definition) { _, updated in draftState.receive(updated) }
    }
}
