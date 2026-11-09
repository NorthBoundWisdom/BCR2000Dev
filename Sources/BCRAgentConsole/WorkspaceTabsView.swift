import BCRAgentCore
import SwiftUI

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case parameters, arm, agents, monitor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parameters: "参数"
        case .arm: "机械臂预览"
        case .agents: "Agent"
        case .monitor: "MIDI 监视"
        }
    }

    var systemImage: String {
        switch self {
        case .parameters: "slider.horizontal.3"
        case .arm: "point.3.connected.trianglepath.dotted"
        case .agents: "square.grid.2x2"
        case .monitor: "waveform.path"
        }
    }
}

struct WorkspaceTabsView: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var tab: WorkspaceTab = .parameters

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("工作区", selection: $tab) {
                ForEach(WorkspaceTab.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)

            switch tab {
            case .parameters: ParameterListView(model: model)
            case .arm: ArmPreviewView(model: model)
            case .agents: AgentGridView(model: model)
            case .monitor: MIDIMonitorView(model: model)
            }
        }
        .panelStyle()
    }
}

// MARK: - Parameters

private struct ParameterListView: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var confirmsDemo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("软件参数是唯一事实来源：拖动滑块会回写所有绑定控件，转动控件也会移动这里的滑块。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.createParameter()
                } label: {
                    Label("新建参数", systemImage: "plus")
                }
                Button("恢复示例配置…") { confirmsDemo = true }
                    .confirmationDialog("恢复机械臂示例配置？", isPresented: $confirmsDemo) {
                        Button("恢复", role: .destructive) { model.restoreDemoConfiguration() }
                    } message: {
                        Text("会替换当前全部参数与功能分配；实体硬件映射不受影响。")
                    }
            }
            .controlSize(.small)

            ForEach(model.configuration.parameterGroups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(group.isEmpty ? "未分组" : group)
                            .font(.subheadline.bold())
                        Spacer()
                        Button("复位到默认") { model.resetGroup(group) }
                            .controlSize(.small)
                    }
                    ForEach(model.configuration.parameters.filter { $0.group == group }) { definition in
                        ParameterRow(model: model, definition: definition)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            }
        }
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
        Text(definition.name).lineLimit(1)
    }

    private var valueText: some View {
        Text(definition.formatted(value))
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
                in: definition.minimum...definition.maximum
            )
        }
    }

    private var chips: some View {
        HStack(spacing: 4) {
            let controls = model.configuration.controls(targeting: .parameter(definition.id))
            if controls.isEmpty {
                Text("未绑定").font(.caption2).foregroundStyle(.tertiary)
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
                        Button(primaryActionTitle(slot.state)) { model.performPrimaryAction(slot.id) }
                            .buttonStyle(.borderedProminent)
                            .tint(stateColor(slot.state))
                        if slot.state == .waitingApproval {
                            Button("拒绝") { model.decline(slot.id) }
                        }
                        Spacer()
                        Text(controls.isEmpty ? "未绑定" : controls.map(\.shortName).joined(separator: " "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                }
                .padding(11)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
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
                Text("IN = 设备 → 软件，OUT = 软件 → 设备。灰色为 Mock 模式下收到但未处理的实体输入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空") { model.clearMonitor() }
                    .controlSize(.small)
            }
            if model.events.isEmpty {
                Text("还没有 MIDI 事件。")
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
                            Text(event.origin == .agent ? "AGENT" : (event.source == .mock ? "MOCK" : "HW  "))
                                .foregroundStyle(.secondary)
                            Text(event.message.diagnosticDescription)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Spacer(minLength: 4)
                            Text(event.control?.shortName ?? "未映射")
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
