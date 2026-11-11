import BCRAgentCore
import SwiftUI

struct ControlInspectorView: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var learnFormat: MIDILearnFormat = .voice
    @State private var confirmsMapReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let control = model.selectedControl {
                    header(control)
                    bindingSection(control)
                    FunctionSection(model: model, control: control).id(control)
                    if let id = model.configuration.assignment(for: control)?.target.parameterID,
                       let definition = model.configuration.parameter(id)
                    {
                        ParameterEditor(model: model, definition: definition)
                            .id(definition.id)
                    }
                } else {
                    Text(L10n.text("在左侧面板选择一个控件"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                BulkAssignmentSection(model: model)
            }
            .padding(14)
            .controlSize(.small)
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
                valueBadge(L10n.text("面板"), "\(model.displayValue(of: control))", color: .primary)
                valueBadge("IN", state.lastInput.map(String.init) ?? "—", color: Theme.parameter)
                valueBadge("OUT", state.lastOutput.map(String.init) ?? "—", color: Theme.selection)
                if model.engine.hardwareMap.midi(for: control)?.kind == .nrpn {
                    valueBadge("14-bit", "\(state.rawValue)", color: Theme.parameter)
                }
                valueBadge(L10n.text("事件"), "\(state.eventCount)", color: .secondary)
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
            SectionTitle(L10n.text("硬件绑定"), icon: "cable.connector")
            if let midi = model.engine.hardwareMap.midi(for: control) {
                Label(midi.description, systemImage: "checkmark.circle.fill")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)
            } else {
                Label(L10n.text("未学习"), systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            }

            switch model.source {
            case .mock:
                FieldNote(L10n.text("Mock 默认预设为通道 1 的 CC。可临时切换单个编码器到通道 16 NRPN，不写入实体映射。"))
                if control.isContinuous {
                    Toggle("Mock 14-bit NRPN", isOn: Binding(
                        get: { model.engine.hardwareMap.midi(for: control)?.kind == .nrpn },
                        set: { model.setMockNRPN($0, for: control) }
                    ))
                    .help(L10n.text("仅切换所选 Mock 编码器的 14-bit NRPN 预设"))
                }
            case .hardware:
                FieldRow(L10n.text("学习消息格式")) {
                    Picker(L10n.text("学习消息格式"), selection: $learnFormat) {
                        Text("CC / Note").tag(MIDILearnFormat.voice)
                        Text("14-bit NRPN").tag(MIDILearnFormat.nrpn14)
                    }
                    .disabled(model.isLearning)
                }
                HStack {
                    if model.isLearning {
                        Button(L10n.text("停止学习")) { model.stopLearning() }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                    } else {
                        Button(L10n.text("从这里开始学习")) { model.beginLearning(at: control, format: learnFormat) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(L10n.text("清除绑定")) { model.unbind(control) }
                        .disabled(model.engine.hardwareMap.midi(for: control) == nil)
                }
                FieldNote(
                    L10n
                        .text(
                            "学习时请操作实体控件：编码器转动、按键按下。完成后自动跳到本区下一个未学习控件。已学习 \(model.learnedCount) / \(BCRLayout.allControls.count)。"
                        )
                )
                Button(L10n.text("清空全部实体映射…"), role: .destructive) { confirmsMapReset = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(model.learnedCount == 0)
                    .confirmationDialog(L10n.text("清空全部实体映射？"), isPresented: $confirmsMapReset) {
                        Button(L10n.text("清空"), role: .destructive) { model.resetHardwareMap() }
                    } message: {
                        Text(L10n.text("功能分配会保留，只删除学到的 MIDI 身份。"))
                    }
            }
        }
        .panelStyle()
    }
}

// MARK: - Function

private enum TargetKind: String, CaseIterable, Identifiable {
    case none, parameter, agent, reset, step, preset, cycle, page, macro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L10n.text("未分配")
        case .parameter: L10n.text("参数")
        case .agent: L10n.text("Agent 主操作")
        case .reset: L10n.text("复位参数组")
        case .step: L10n.text("参数步进")
        case .preset: L10n.text("设为指定值")
        case .cycle: L10n.text("循环预设值")
        case .page: L10n.text("切换页面")
        case .macro: L10n.text("执行宏")
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
        case .switchPage?: self = .page
        case .runMacro?: self = .macro
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
            SectionTitle(L10n.text("功能"), icon: "slider.horizontal.3")

            FieldRow(L10n.text("类型")) {
                Picker(L10n.text("类型"), selection: kindBinding) {
                    ForEach(availableKinds) { Text($0.title).tag($0) }
                }
            }

            switch assignment?.target {
            case let .switchPage(id)?:
                FieldRow(L10n.text("页面")) {
                    Picker(
                        L10n.text("页面"),
                        selection: Binding(get: { id }, set: { update(target: .switchPage($0)) })
                    ) {
                        Text(L10n.text("基础页面")).tag(SurfaceConfiguration.basePageID)
                        ForEach(model.configuration.pages) { Text($0.name).tag($0.id) }
                    }
                }
            case let .runMacro(id)?:
                FieldRow(L10n.text("宏")) {
                    Picker(L10n.text("宏"), selection: Binding(get: { id }, set: { update(target: .runMacro($0)) })) {
                        ForEach(model.configuration.macros) { Text($0.name).tag($0.id) }
                    }
                }

            case let .parameter(id)?:
                FieldRow(L10n.text("参数")) {
                    HStack(spacing: 6) {
                        Picker(L10n.text("参数"), selection: Binding(
                            get: { id },
                            set: { update(target: .parameter($0)) }
                        )) {
                            ForEach(model.configuration.parameters) { parameter in
                                Text(parameter.group.isEmpty ? parameter
                                    .name : "\(parameter.group) · \(parameter.name)")
                                    .tag(parameter.id)
                            }
                        }
                        Button {
                            model.createParameter(assigningTo: control)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(L10n.text("新建参数并分配给此控件"))
                        .accessibilityLabel(L10n.text("新建参数并分配给此控件"))
                    }
                }
                if !control.isContinuous {
                    FieldRow(L10n.text("按键行为")) {
                        Picker(L10n.text("按键行为"), selection: Binding(
                            get: { assignment?.buttonBehavior ?? .toggle },
                            set: { behavior in modify { $0.buttonBehavior = behavior } }
                        )) {
                            ForEach(ButtonBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                if control.isContinuous {
                    FieldRow(L10n.text("编码器模式")) {
                        Picker(L10n.text("编码器模式"), selection: Binding(
                            get: { assignment?.encoderMode ?? .absolute },
                            set: { value in modify { $0.encoderMode = value } }
                        )) {
                            Text(L10n.text("绝对")).tag(EncoderMode.absolute)
                            Text(L10n.text("相对 1")).tag(EncoderMode.relative1)
                            Text(L10n.text("相对 2")).tag(EncoderMode.relative2)
                        }
                        .pickerStyle(.segmented)
                        .help(L10n.text("相对模式：1 为补码，2 为二进制偏移；待 R1 实机验证"))
                    }
                    if assignment?.encoderMode != .absolute {
                        FieldRow(L10n.text("相对步长")) {
                            TextField(L10n.text("相对步长"), value: Binding(
                                get: { assignment?.encoderStep ?? 1 },
                                set: { value in modify { $0.encoderStep = value } }
                            ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(L10n.text("相对步长"))
                                .help(L10n.text("设置相对编码器每格步长"))
                        }
                        FieldNote(L10n.text("每格步长 × 消息幅度（加速度）。灯环保持绝对位置；参数吸附仍生效。"))
                    }
                }
                FieldIndent {
                    Toggle(L10n.text("反向"), isOn: Binding(
                        get: { assignment?.inverted ?? false },
                        set: { inverted in modify { $0.inverted = inverted } }
                    ))
                }
                let shared = model.configuration.controls(targetingParameter: id).filter { $0 != control }
                if !shared.isEmpty {
                    FieldNote(L10n.text("同一参数也绑定在：\(shared.map(\.shortName).joined(separator: "、"))，会互相同步。"))
                }

            case let .agentPrimaryAction(slot)?:
                FieldRow(L10n.text("槽位")) {
                    Picker(L10n.text("槽位"), selection: Binding(
                        get: { slot.rawValue },
                        set: { update(target: .agentPrimaryAction(AgentSlotID($0))) }
                    )) {
                        ForEach(1 ... 8, id: \.self) { Text("Agent \($0)").tag($0) }
                    }
                }
                FieldNote(L10n.text("空闲时启动、运行时中断、等待批准时批准；LED 亮度表示 Agent 状态。"))

            case .stepParameter?, .setParameter?, .cycleParameter?:
                if let target = assignment?.target {
                    TriggerParameterEditor(model: model, control: control, target: target)
                }

            case let .resetGroup(group)?:
                FieldRow(L10n.text("参数组")) {
                    Picker(L10n.text("参数组"), selection: Binding(
                        get: { group },
                        set: { update(target: .resetGroup($0)) }
                    )) {
                        ForEach(model.configuration.parameterGroups, id: \.self) {
                            Text($0.isEmpty ? L10n.text("（未分组）") : $0).tag($0)
                        }
                    }
                }
                FieldNote(L10n.text("按下时把该组全部参数恢复为默认值，并回写所有绑定控件。"))

            case nil:
                FieldNote(control.isContinuous
                    ? L10n.text("未分配的编码器仍会显示原始值；在实体模式下拖动会直接回写灯环，便于测试。")
                    : L10n.text("选择“参数”可做开关/按住，选择触发类功能可启动 Agent 或复位。"))
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
                    let id = assignment?.target.parameterID ?? model.configuration.parameters.first?.id ?? model
                        .createParameter()
                    guard let id, let definition = model.configuration.parameter(id) else { return }
                    switch kind {
                    case .step: update(target: .stepParameter(id: id, step: definition.step ?? 1, wraps: false))
                    case .preset: update(target: .setParameter(id: id, value: definition.defaultValue))
                    case .cycle:
                        var seen = Set<Double>()
                        let values = [definition.minimum, definition.clamp(definition.defaultValue), definition.maximum]
                            .filter { seen.insert($0).inserted }
                        update(target: .cycleParameter(id: id, values: values))
                    default: break
                    }
                case .page: update(target: .switchPage(SurfaceConfiguration.basePageID))
                case .macro:
                    if let macro = model.configuration.macros.first { update(target: .runMacro(macro.id)) }
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
        if target.isTrigger || target.parameterID.flatMap({ model.configuration.parameter($0) })?
            .kind != .continuous { next.encoderMode = .absolute }
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
                SectionTitle(L10n.text("参数定义"), icon: "function")
                Spacer()
                Text(definition.id.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            if let value = model.engine.value(of: definition.id) {
                HStack {
                    Text(definition.formatted(
                        value,
                        minimumFractionDigits: model.parameterFractionDigits(definition.id)
                    ))
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
                            in: definition.minimum ... definition.maximum
                        )
                    }
                }
            }

            if let conflict = draftState.conflict {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("参数已在其他位置修改，请处理草稿冲突。")).foregroundStyle(.orange)
                    HStack {
                        Button(L10n.text("采用新值")) { draftState.reload(conflict) }
                            .accessibilityLabel(L10n.text("采用新值"))
                            .accessibilityIdentifier("parameter.adoptExternal")
                            .help(L10n.text("采用外部参数定义，放弃当前草稿"))
                        Button(L10n.text("保留草稿")) { draftState.keepDraft() }
                            .accessibilityLabel(L10n.text("保留草稿"))
                            .accessibilityIdentifier("parameter.keepDraft")
                            .help(L10n.text("保留当前草稿，稍后应用将覆盖外部修改"))
                    }
                    Text(L10n.text("保留草稿后再应用，将覆盖新定义。")).foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 8) {
                textRow(L10n.text("名称"), $draftState.value.name)
                textRow(L10n.text("分组"), $draftState.value.group)
                textRow(L10n.text("单位"), $draftState.value.unit)
                FieldRow(L10n.text("类型")) {
                    Picker(L10n.text("类型"), selection: $draftState.value.kind) {
                        ForEach(ParameterKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                numberRow(L10n.text("最小值"), $draftState.value.minimum)
                numberRow(L10n.text("最大值"), $draftState.value.maximum)
                numberRow(L10n.text("默认值"), $draftState.value.defaultValue)
                FieldIndent { Toggle(L10n.text("允许 Agent 写入"), isOn: $draftState.value.agentWritable) }
                FieldIndent {
                    Toggle(L10n.text("启用步长吸附"), isOn: Binding(
                        get: { draftState.value.step != nil },
                        set: { draftState.value.step = $0 ? (draftState.value.step ?? 1) : nil }
                    ))
                }
                if draftState.value.step != nil {
                    numberRow(L10n.text("步长"), Binding(
                        get: { draftState.value.step ?? 1 }, set: { draftState.value.step = $0 }
                    ))
                }
            }

            HStack {
                Button(L10n.text("应用修改")) {
                    if let applied = model.updateParameter(draftState.value) { draftState.reload(applied) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draftState.isDirty || draftState.conflict != nil)
                Button(L10n.text("还原")) { draftState.reload(definition) }
                    .disabled(!draftState.isDirty && draftState.conflict == nil)
                Spacer()
                Button(L10n.text("删除参数…"), role: .destructive) { confirmsRemoval = true }
                    .confirmationDialog(L10n.text("删除参数“\(definition.name)”？"), isPresented: $confirmsRemoval) {
                        Button(L10n.text("删除"), role: .destructive) { model.removeParameter(definition.id) }
                    } message: {
                        Text(L10n.text("所有绑定到它的控件都会变为未分配。"))
                    }
            }
        }
        .panelStyle()
        .onChange(of: definition) { _, updated in draftState.receive(updated) }
    }

    private func textRow(_ label: String, _ text: Binding<String>) -> some View {
        FieldRow(label) {
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }
    }

    private func numberRow(_ label: String, _ value: Binding<Double>) -> some View {
        FieldRow(label) {
            TextField(label, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }
    }
}
