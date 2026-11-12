import BCRAgentCore
import SwiftUI

/// Preview and confirm aligning the device's temporary preset with the software configuration.
struct PresetAlignmentSheet: View {
    @ObservedObject var model: ConsoleViewModel
    let state: PresetAlignmentState
    @State private var expandedChangeKinds: Set<String> = []

    private static let changeKinds: [BCRPresetAlignment.Change.Kind] = [
        .newButton, .readdressedButton, .ringMode, .buttonBehavior, .lock, .enabledFunction
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.text("对齐设备预设"), systemImage: "slider.horizontal.below.square.and.square.filled")
                .font(.title2.bold())
            Text(L10n.text("按软件配置修改设备当前的临时预设：补齐按键、设置灯环与按键行为、锁定预设键。不写入永久存储，设备断电或重新载入预设即恢复原样。"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
            Divider()
            HStack {
                if let backup = state.backup {
                    Text(L10n.text("写入前备份：\(backup.lastPathComponent)"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .help(backup.path)
                }
                Spacer()
                if state.canRestore || (model.presetRestorePoint != nil && state.phase != .preview) {
                    Button(L10n.text("恢复写入前的预设")) { model.restorePresetBeforeAlignment() }
                        .disabled(state.phase.isBusy)
                        .accessibilityIdentifier("preset.restore")
                }
                Button(state.phase == .finished ? L10n.text("完成") : L10n.text("关闭")) { model.dismissPresetAlignment() }
                    .accessibilityIdentifier("preset.close")
                    .keyboardShortcut(.cancelAction)
                    .disabled(state.phase.isBusy)
                if state.phase == .preview {
                    Button(L10n.text("写入设备")) { model.applyPresetAlignment() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.plan?.isEmpty ?? true)
                        .accessibilityIdentifier("preset.write")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("preset.dialog")
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(state.phase.isBusy)
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .reading:
            ProgressView(L10n.text("正在读取设备当前预设（只读）…"))
                .accessibilityIdentifier("preset.reading")
        case .preview:
            VStack(alignment: .leading, spacing: 14) {
                options
                changes
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("preset.preview")
        case let .writing(done, total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text(L10n.text("正在逐行写入并等待设备确认：\(done)/\(total)；请暂勿操作设备。"))
            }
            .accessibilityIdentifier("preset.writing")
        case .verifying:
            ProgressView(L10n.text("正在回读核对…"))
                .accessibilityIdentifier("preset.verifying")
        case .restoring:
            ProgressView(L10n.text("正在恢复写入前的预设…"))
                .accessibilityIdentifier("preset.restoring")
        case .finished:
            Label(L10n.text("设备与软件已对齐。"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("preset.finished")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("preset.failed")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var options: some View {
        let binding = { (keyPath: WritableKeyPath<BCRPresetAlignment.Options, Bool>) in
            Binding(get: { state.options[keyPath: keyPath] }, set: { value in
                var options = state.options
                options[keyPath: keyPath] = value
                model.setAlignmentOptions(options)
            })
        }
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(L10n.text("补齐未配置及与旋钮同址的按键"), isOn: binding(\.completeButtons))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("preset.option.completeButtons")
            Toggle(L10n.text("按参数范围设置顶部旋钮灯环（±范围用居中，0 起的单位量用进度条）"), isOn: binding(\.ringModes))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("preset.option.ringModes")
            Toggle(L10n.text("按键统一发送按下/松开，开关状态和灯由软件决定"), isOn: binding(\.buttonBehavior))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("preset.option.buttonBehavior")
            Toggle(L10n.text("锁定 PRESET 与编程键，防止设备换预设后与软件不一致"), isOn: binding(\.lockPreset))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("preset.option.lockPreset")
            Toggle(L10n.text("启用实体按键的已分配功能（如使能、Agent 键）"), isOn: binding(\.enableButtonFunctions))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("preset.option.enableButtonFunctions")
            if state.options.enableButtonFunctions {
                Text(L10n.text("启用后按下实体按键会立即执行功能，包括输出使能；请确认分配无误。"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder private var changes: some View {
        if let error = state.planError {
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let plan = state.plan {
            if plan.isEmpty {
                Text(L10n.text("设备预设已与软件一致，无需写入。"))
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.text("将修改 \(plan.changes.count) 项，共写入 \(plan.lines.count) 行 BCL：")).font(.headline)
                let count = { (kind: BCRPresetAlignment.Change.Kind) in plan.changes.filter { $0.kind == kind }.count }
                Text(L10n
                    .text(
                        "新增 \(count(.newButton)) · 改址 \(count(.readdressedButton)) · 灯环 \(count(.ringMode)) · 按键 \(count(.buttonBehavior)) · 锁定 \(count(.lock)) · 启用 \(count(.enabledFunction))"
                    ))
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityIdentifier("preset.changes.summary")
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Self.changeKinds, id: \.rawValue) { kind in
                            let items = plan.changes.filter { $0.kind == kind }
                            if !items.isEmpty { changeGroup(kind, changes: items) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(8)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.insetRadius))
                if state.options.lockPreset {
                    Text(L10n.text("锁定后，设备上的 PRESET、STORE、LEARN、EDIT、EXIT 键暂不可用；设备断电或在此恢复即解除。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func changeGroup(_ kind: BCRPresetAlignment.Change.Kind,
                             changes: [BCRPresetAlignment.Change]) -> some View
    {
        let expanded = expandedChangeKinds.contains(kind.rawValue)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                if expanded { expandedChangeKinds.remove(kind.rawValue) }
                else { expandedChangeKinds.insert(kind.rawValue) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 10).accessibilityHidden(true)
                    Text(L10n.text("\(Self.title(kind))：\(changes.count) 项"))
                        .font(.caption.bold())
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("preset.changeGroup.\(kind.rawValue)")
            .accessibilityValue(expanded ? L10n.text("已展开") : L10n.text("已折叠"))
            .help(L10n.text("展开或收起此类修改"))
            if expanded {
                ForEach(Array(changes.enumerated()), id: \.offset) { index, change in
                    HStack(alignment: .top, spacing: 8) {
                        Text(change.control?.shortName ?? "—").monospaced()
                            .frame(width: 56, alignment: .leading)
                        Text(change.detail).monospaced()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                    .padding(.leading, 16)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("preset.changeRow.\(kind.rawValue).\(index)")
                }
            }
        }
    }

    private static func title(_ kind: BCRPresetAlignment.Change.Kind) -> String {
        switch kind {
        case .newButton: L10n.text("新增按键")
        case .readdressedButton: L10n.text("改址按键")
        case .ringMode: L10n.text("灯环模式")
        case .buttonBehavior: L10n.text("按键行为")
        case .lock: L10n.text("预设锁定")
        case .enabledFunction: L10n.text("启用功能")
        }
    }
}
