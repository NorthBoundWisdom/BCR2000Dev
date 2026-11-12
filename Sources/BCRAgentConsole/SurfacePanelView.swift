import BCRAgentCore
import SwiftUI

/// Everything the panel needs to draw one physical control.
struct ControlPresentation {
    let control: BCRControlID
    let value: UInt8
    let ringLEDs: Set<Int>?
    let hardwarePressed: Bool
    let label: String?
    let detail: String?
    let accent: Color
    let isBound: Bool
    let isSelected: Bool
    let isLearnTarget: Bool
}

extension ConsoleViewModel {
    func presentation(of control: BCRControlID) -> ControlPresentation {
        let assignment = configuration.assignment(for: control)
        var label: String?
        var detail: String?
        var accent = Color.secondary
        switch assignment?.target {
        case let .switchPage(id)?:
            label = configuration.pages.first(where: { $0.id == id })?.name ?? L10n.text("基础页面")
            accent = Theme.trigger
        case let .runMacro(id)?:
            label = configuration.macros.first(where: { $0.id == id })?.name ?? L10n.text("宏")
            accent = Theme.trigger
        case let .parameter(id)?:
            if let definition = configuration.parameter(id), let value = engine.value(of: id) {
                label = definition.name
                detail = definition.formatted(value, minimumFractionDigits: parameterFractionDigits(id))
                accent = Theme.parameter
            }
        case let .agentPrimaryAction(slotID)?:
            label = "Agent \(slotID.rawValue)"
            if let slot = slot(slotID) {
                detail = slot.state.displayName
                accent = stateColor(slot.state)
            }
        case let .resetGroup(group)?:
            label = L10n.text("复位 \(group)")
            accent = Theme.trigger
        case let .stepParameter(id, step, _)?:
            label = step > 0 ? L10n.text("步进 +") : L10n.text("步进 −")
            detail = configuration.parameter(id)?.name
            accent = Theme.trigger
        case let .setParameter(id, value)?:
            label = L10n.text("设为 ") + (configuration.parameter(id)?.formatted(value) ?? String(value))
            detail = configuration.parameter(id)?.name
            accent = Theme.trigger
        case let .cycleParameter(id, values)?:
            label = L10n.text("循环 \(values.count) 个值")
            detail = configuration.parameter(id)?.name
            accent = Theme.trigger
        case nil:
            break
        }
        return ControlPresentation(
            control: control,
            value: displayValue(of: control),
            ringLEDs: source == .mock ? mock.ringLEDs(of: control)
                : engine.hardwareMap.ringMode(for: control)?.litLEDs(value: displayValue(of: control)),
            hardwarePressed: connection.isConnected && hardwarePressedControls.contains(control.section == .pushEncoder
                ? .pushEncoderButton(group: control.row, control.index) : control),
            label: label,
            detail: detail,
            accent: accent,
            isBound: engine.hardwareMap.midi(for: control) != nil,
            isSelected: selectedControl == control,
            isLearnTarget: engine.learnTarget == control
        )
    }
}

/// Panel geometry at a given scale. Every panel dimension derives from these base values so the
/// overall size is predictable: `naturalSize * scale`.
struct PanelMetrics: Equatable {
    /// Natural panel size at scale 1, used by the window layout to pick a scale.
    static let naturalSize = CGSize(width: 800, height: 755)
    static let scaleRange: ClosedRange<CGFloat> = 1 ... 1.6

    var scale: CGFloat = 1

    func callAsFunction(_ value: CGFloat) -> CGFloat {
        value * scale
    }

    func font(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * scale, weight: weight, design: design)
    }
}

private struct PanelMetricsKey: EnvironmentKey {
    static let defaultValue = PanelMetrics()
}

extension EnvironmentValues {
    var panelMetrics: PanelMetrics {
        get { self[PanelMetricsKey.self] }
        set { self[PanelMetricsKey.self] = newValue }
    }
}

struct SurfacePanelView: View {
    @ObservedObject var model: ConsoleViewModel
    @Environment(\.panelMetrics) private var m

    // Base widths: 18 + 28 + 6 + 8 × 74 + 7 × 6 + 16 + 80 + 18 = 800 (PanelMetrics.naturalSize).
    private var spacing: CGFloat { m(6) }

    var body: some View {
        VStack(alignment: .leading, spacing: m(12)) {
            header
            HStack(alignment: .top, spacing: m(16)) {
                VStack(alignment: .leading, spacing: m(10)) {
                    row("P\(model.visibleGroup)") {
                        ForEach(1 ... 8, id: \.self) { index in
                            VStack(spacing: m(4)) {
                                knob(.pushEncoder(group: model.visibleGroup, index))
                                pushButton(.pushEncoderButton(group: model.visibleGroup, index))
                            }
                        }
                    }
                    divider
                    ForEach(1 ... 2, id: \.self) { line in
                        row("B\(line)") {
                            ForEach(1 ... 8, id: \.self) { index in pad(.button(row: line, index)) }
                        }
                    }
                    divider
                    ForEach(1 ... 3, id: \.self) { line in
                        row("E\(line)") {
                            ForEach(1 ... 8, id: \.self) { index in knob(.encoder(row: line, index)) }
                        }
                    }
                }
                sideColumn
            }
        }
        .padding(m(18))
        .frame(width: PanelMetrics.naturalSize.width * m.scale, alignment: .leading)
        .background {
            // Shadow the chassis shape, not the full subtree of controls and native views.
            // A subtree-wide shadow stalls WindowServer composition during window movement.
            RoundedRectangle(cornerRadius: m(18))
                .fill(LinearGradient(
                    colors: [Theme.chassisTop, Theme.chassisBottom],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: m(18)).stroke(Color.white.opacity(0.12))
        }
    }

    private var header: some View {
        HStack(spacing: m(10)) {
            Text("BCR2000")
                .font(m.font(17, weight: .heavy, design: .rounded))
                .tracking(2 * m.scale)
            Text(model.source == .mock ? "MOCK DEVICE" : "HARDWARE MIRROR")
                .font(m.font(9.5, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, m(7))
                .padding(.vertical, m(3))
                .foregroundStyle(model.source == .mock ? Theme.parameter : Theme.selection)
                .background((model.source == .mock ? Theme.parameter : Theme.selection).opacity(0.14), in: Capsule())
            if model.source == .hardware {
                Button {
                    model.beginPresetAlignment()
                } label: {
                    Label(L10n.text("对齐设备预设"), systemImage: "slider.horizontal.below.square.and.square.filled")
                        .font(m.font(9.5, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canAlignPreset)
                .help(L10n.text("读取设备当前临时预设，预览按软件配置所需的修改；确认后才写入，不写永久存储。"))
                if model.presetRestorePoint != nil {
                    Button {
                        model.restorePresetBeforeAlignment()
                    } label: {
                        Label(L10n.text("恢复原预设"), systemImage: "arrow.uturn.backward")
                            .font(m.font(9.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.canRestorePreset)
                    .help(L10n.text("把最近一次对齐前备份的临时预设写回设备，并恢复当时的本机映射。"))
                }
            }
            Spacer()
            Text(model.source == .mock
                ? L10n.text("拖动旋钮 / 按下按键 = 模拟实体操作")
                : L10n.text("拖动旋钮 / 按下按键 = 软件修改并回写硬件"))
                .font(m.font(10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, m(34))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            Text(title)
                .font(m.font(9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: m(28))
                .padding(.top, m(24))
            content()
        }
    }

    /// Right-hand column in the device's order: display, status LEDs, encoder groups, fixed
    /// programming keys, the four user keys and the preset keys. Device-local keys are drawn but
    /// disabled: the BCR2000 neither reports them over MIDI nor accepts them from the computer.
    private var sideColumn: some View {
        VStack(spacing: m(8)) {
            LEDDisplay(text: model.displayText, busy: model.displayBusy)
                .help(L10n.text("按设备规则重现：操作开启“显示数值”的控件时短暂显示其数值或 on/oFF，其余时间显示预设号；设备不报告预设号，仅在本软件载入预设后显示。"))
            if let name = model.displayPresetName {
                Text(name)
                    .font(m.font(7.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .help(L10n.text("设备当前预设名称（读取预设时获得）"))
            }
            statusLEDs
            sideLabel(model.source == .hardware ? L10n.text("查看分组") : "ENCODER GROUP")
            if model.source == .hardware {
                Text(model.observedHardwareGroup.map { L10n.text("最后输入组 \($0)") }
                    ?? model.startupConfiguredGroup.map { L10n.text("启动设为组 \($0)") }
                    ?? L10n.text("硬件组未确认"))
                    .font(m.font(7.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            keyGrid {
                ForEach(BCRLayout.encoderGroups, id: \.self) { group in
                    Button {
                        model.selectGroup(group)
                    } label: {
                        DeviceKey(label: "\(group)", lit: group == model.visibleGroup)
                    }
                    .buttonStyle(.plain)
                }
            }
            .help(model.source == .mock
                ? L10n.text("切换 Mock 设备的编码器组（与实体一样不发送 MIDI）")
                : L10n.text("实体设备不会报告当前组；这里只切换显示。操作实体编码器时会自动跟随。"))
            keyGrid {
                ForEach(["STORE", "LEARN", "EDIT", "EXIT"], id: \.self) { DeviceKey(label: $0, enabled: false) }
            }
            .help(L10n.text("设备本机编程键：不发送也不接收 MIDI，软件无法读取或操作，仅作对照显示。"))

            Spacer(minLength: m(12))

            sideLabel("USER")
            keyGrid {
                ForEach(1 ... 4, id: \.self) { index in userKey(.userButton(index)) }
            }
            sideLabel("PRESET")
            keyGrid {
                DeviceKey(systemImage: "arrowtriangle.left.fill", enabled: false)
                DeviceKey(systemImage: "arrowtriangle.right.fill", enabled: false)
            }
            .help(L10n.text("实体预设切换只在设备本机生效，不通知软件；请在设备上操作。"))
        }
        .frame(width: m(80))
    }

    private var statusLEDs: some View {
        let usb = model.source == .hardware && model.connection.isConnected
        return HStack(spacing: m(6)) {
            StatusLED(label: "USB", lit: usb)
                .help(L10n.text("实体 Port 1 已连接时点亮"))
            ForEach(["IN", "A", "B"], id: \.self) { StatusLED(label: $0, lit: false) }
                .help(L10n.text("MIDI IN / OUT A / OUT B 指示 DIN 接口流量，设备不向软件报告，仅作对照显示。"))
        }
    }

    private func sideLabel(_ text: String) -> some View {
        Text(text)
            .font(m.font(7.5, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func keyGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.fixed(m(36)), spacing: m(6)), GridItem(.fixed(m(36)))], spacing: m(6)) {
            content()
        }
    }

    private func userKey(_ control: BCRControlID) -> some View {
        UserKeyCell(
            presentation: model.presentation(of: control),
            onPress: { model.press(control) },
            onRelease: { model.release(control) }
        )
    }

    private func knob(_ control: BCRControlID) -> some View {
        KnobCell(
            presentation: model.presentation(of: control),
            onTouch: { model.touch(control) },
            onTurn: { model.turn(control, by: $0) }
        )
    }

    private func pad(_ control: BCRControlID) -> some View {
        PadCell(
            presentation: model.presentation(of: control),
            onPress: { model.press(control) },
            onRelease: { model.release(control) }
        )
    }

    private func pushButton(_ control: BCRControlID) -> some View {
        PushButtonCell(
            presentation: model.presentation(of: control),
            onPress: { model.press(control) },
            onRelease: { model.release(control) }
        )
    }
}

// MARK: - Cells

/// The 4-digit red LED display.
private struct LEDDisplay: View {
    let text: String
    var busy = false
    @Environment(\.panelMetrics) private var m

    var body: some View {
        Group {
            if busy {
                TimelineView(.periodic(from: .now, by: 1.0 / 12)) { context in
                    BusySegments(frame: BCRDisplayModel.busyFrame(
                        at: context.date.timeIntervalSinceReferenceDate
                    ))
                }
            } else {
                Text(String(text.suffix(4)).leftPadded(to: 4))
                    .font(m.font(17, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.led)
                    .shadow(color: Theme.led.opacity(0.7), radius: 3)
            }
        }
        .frame(width: m(78), height: m(30))
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: m(4)))
        .overlay { RoundedRectangle(cornerRadius: m(4)).stroke(Color.white.opacity(0.1)) }
        .accessibilityLabel(L10n.text("LED 显示"))
        .accessibilityValue(busy ? L10n.text("设备正在传输预设") : text)
    }
}

/// One lit segment chasing around the outline of four 7-segment digits (top row left to right,
/// right side, bottom row right to left, left side), conveying the device's busy display.
private struct BusySegments: View {
    let frame: Int
    @Environment(\.panelMetrics) private var m

    var body: some View {
        HStack(spacing: m(4)) {
            ForEach(0 ..< 4, id: \.self) { digit in
                VStack(spacing: m(12)) {
                    bar(lit: frame == digit, vertical: false)
                    bar(lit: frame == 9 - digit, vertical: false)
                }
                .overlay(alignment: .leading) { if digit == 0 { bar(lit: frame >= 10, vertical: true) } }
                .overlay(alignment: .trailing) { if digit == 3 { bar(lit: frame == 4 || frame == 5, vertical: true) } }
            }
        }
    }

    private func bar(lit: Bool, vertical: Bool) -> some View {
        Capsule()
            .fill(lit ? Theme.led : Theme.led.opacity(0.12))
            .shadow(color: lit ? Theme.led.opacity(0.7) : .clear, radius: 3)
            .frame(width: m(vertical ? 2.5 : 12), height: m(vertical ? 12 : 2.5))
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: " ", count: max(0, length - count)) + self
    }
}

private struct StatusLED: View {
    let label: String
    let lit: Bool
    @Environment(\.panelMetrics) private var m

    var body: some View {
        VStack(spacing: m(2)) {
            Circle()
                .fill(lit ? Theme.led : Theme.ledOff)
                .frame(width: m(4.5), height: m(4.5))
                .shadow(color: lit ? Theme.led : .clear, radius: 2.5)
            Text(label)
                .font(m.font(6, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}

/// A small square device key. Disabled keys are device-local and cannot be synchronized.
private struct DeviceKey: View {
    var label: String?
    var systemImage: String?
    var lit = false
    var enabled = true
    @Environment(\.panelMetrics) private var m

    var body: some View {
        VStack(spacing: m(3)) {
            Capsule()
                .fill(lit ? Theme.led : Theme.ledOff)
                .frame(width: m(16), height: m(3))
                .shadow(color: lit ? Theme.led : .clear, radius: 3)
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(m.font(8))
                } else {
                    Text(label ?? "").font(m.font(label?.count == 1 ? 10 : 7, weight: .bold).monospacedDigit())
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(width: m(36), height: m(28))
        .background(Color.black.opacity(enabled ? 0.35 : 0.2), in: RoundedRectangle(cornerRadius: m(6)))
        .overlay { RoundedRectangle(cornerRadius: m(6)).stroke(Color.white.opacity(enabled ? 0.08 : 0.04)) }
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? systemImage ?? "")
        .accessibilityAddTraits(enabled ? .isButton : [])
    }
}

/// Compact USER key laid out 2 × 2 like the device; label and value are in the inspector and help.
private struct UserKeyCell: View {
    let presentation: ControlPresentation
    @Environment(\.panelMetrics) private var m
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isDown = false

    var body: some View {
        let down = isDown || presentation.hardwarePressed
        let level = Double(presentation.value) / 127
        VStack(spacing: m(2)) {
            Capsule()
                .fill(level > 0 ? Theme.led.opacity(0.35 + 0.65 * level) : Theme.ledOff)
                .frame(width: m(16), height: m(3))
                .shadow(color: level > 0 ? Theme.led.opacity(level) : .clear, radius: 3)
            Text(presentation.control.shortName)
                .font(m.font(8, weight: .bold, design: .monospaced))
            Text(presentation.label ?? L10n.text("未分配"))
                .font(m.font(6.5, weight: .semibold))
                .foregroundStyle(presentation
                    .label == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(presentation.accent))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, m(2))
        .frame(width: m(36), height: m(40))
        .background(
            down ? Color.white.opacity(0.2) : Color.black.opacity(0.35),
            in: RoundedRectangle(cornerRadius: m(6))
        )
        .overlay {
            RoundedRectangle(cornerRadius: m(6)).stroke(
                presentation.isLearnTarget ? Theme.learn
                    :
                    (presentation.isSelected ? Theme.selection : Color.white
                        .opacity(presentation.hardwarePressed ? 0.5 : 0.08)),
                lineWidth: presentation.isLearnTarget ? 2 : 1
            )
        }
        .overlay(alignment: .topTrailing) {
            if !presentation.isBound {
                Circle().fill(.orange).frame(width: m(4), height: m(4)).padding(m(3))
            }
        }
        .scaleEffect(down ? 0.94 : 1)
        .animation(.easeOut(duration: 0.1), value: down)
        .modifier(PressGesture(isDown: $isDown, onPress: onPress, onRelease: onRelease))
        .help(
            "\(presentation.control.description) · \(presentation.label ?? L10n.text("未分配")) · \(presentation.detail ?? "\(presentation.value)")"
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.control.description) \(presentation.label ?? L10n.text("未分配"))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onPress()
            onRelease()
        }
    }
}

private struct CellChrome: ViewModifier {
    let presentation: ControlPresentation
    @Environment(\.panelMetrics) private var m

    func body(content: Content) -> some View {
        content
            .frame(width: m(74))
            .padding(.vertical, m(5))
            .background(
                presentation.isSelected ? Theme.selection.opacity(0.14) : Color.black.opacity(0.18),
                in: RoundedRectangle(cornerRadius: m(9))
            )
            .overlay {
                RoundedRectangle(cornerRadius: m(9))
                    .stroke(
                        presentation.isLearnTarget ? Theme.learn
                            : (presentation.isSelected ? Theme.selection : Color.white.opacity(0.04)),
                        lineWidth: presentation.isLearnTarget ? 2 : 1
                    )
            }
            .overlay(alignment: .topTrailing) {
                if !presentation.isBound {
                    Image(systemName: "questionmark.circle.fill")
                        .font(m.font(9))
                        .foregroundStyle(.orange)
                        .padding(m(4))
                        .help(L10n.text("此控件尚未学习 MIDI 身份"))
                }
            }
    }
}

private struct CellLabels: View {
    let presentation: ControlPresentation
    @Environment(\.panelMetrics) private var m

    var body: some View {
        VStack(spacing: 1) {
            Text(presentation.control.shortName)
                .font(m.font(8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(presentation.label ?? L10n.text("未分配"))
                .font(m.font(10, weight: .semibold))
                .foregroundStyle(presentation
                    .label == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(presentation.accent))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(presentation.detail ?? "\(presentation.value)")
                .font(m.font(9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, m(3))
    }
}

private struct KnobCell: View {
    let presentation: ControlPresentation
    @Environment(\.panelMetrics) private var m
    let onTouch: () -> Void
    let onTurn: (Int) -> Void

    var body: some View {
        VStack(spacing: m(3)) {
            ZStack {
                LEDRing(litLEDs: presentation.ringLEDs)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.30), Color(white: 0.11)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay { Circle().stroke(Color.white.opacity(0.12)) }
                    .frame(width: m(38), height: m(38))
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                    .scaleEffect(presentation.hardwarePressed ? 0.92 : 1)
                    .offset(y: presentation.hardwarePressed ? m(1.5) : 0)
                    .animation(.easeOut(duration: 0.1), value: presentation.hardwarePressed)
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: m(2.5), height: m(11))
                    .offset(y: m(-12))
                    .rotationEffect(.degrees(-135 + Double(presentation.value) / 127 * 270))
                KnobValueInput(onTouch: onTouch, onDelta: onTurn)
            }
            .frame(width: m(60), height: m(60))
            CellLabels(presentation: presentation)
        }
        .modifier(CellChrome(presentation: presentation))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.control.description) \(presentation.label ?? L10n.text("未分配"))")
        .accessibilityValue(presentation.detail ?? "\(presentation.value)")
        .accessibilityAdjustableAction { direction in
            onTurn(direction == .increment ? 1 : -1)
        }
    }
}

private struct LEDRing: View {
    let litLEDs: Set<Int>?
    @Environment(\.panelMetrics) private var m
    private let count = LEDRingMode.count

    var body: some View {
        ZStack {
            ForEach(0 ..< count, id: \.self) { led in
                Circle()
                    .fill(litLEDs?.contains(led) == true ? Theme.led : Theme.ledOff)
                    .frame(width: m(4), height: m(4))
                    .shadow(color: litLEDs?.contains(led) == true ? Theme.led.opacity(0.9) : .clear, radius: 2.5)
                    .offset(y: m(-27))
                    .rotationEffect(.degrees(-135 + Double(led) * 270 / Double(count - 1)))
            }
            if litLEDs == nil {
                Text("?").font(.caption2).foregroundStyle(.secondary).offset(y: m(26))
            }
        }
        .help(litLEDs == nil ? L10n.text("灯环模式未知或尚未校准，请读取当前预设") : "")
    }
}

private struct PressGesture: ViewModifier {
    @Binding var isDown: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isDown else { return }
                    isDown = true
                    onPress()
                }
                .onEnded { _ in
                    isDown = false
                    onRelease()
                }
        )
    }
}

private struct PadCell: View {
    let presentation: ControlPresentation
    @Environment(\.panelMetrics) private var m
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isDown = false

    var body: some View {
        VStack(spacing: m(4)) {
            RoundedRectangle(cornerRadius: m(6))
                .fill(
                    LinearGradient(
                        colors: isDown || presentation.hardwarePressed ? [Color(white: 0.22), Color(white: 0.16)] : [
                            Color(white: 0.30),
                            Color(white: 0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay { RoundedRectangle(cornerRadius: m(6)).stroke(Color.white.opacity(0.12)) }
                .overlay {
                    let level = Double(presentation.value) / 127
                    Capsule()
                        .fill(level > 0 ? Theme.led.opacity(0.35 + 0.65 * level) : Theme.ledOff)
                        .frame(width: m(24), height: m(4))
                        .shadow(color: level > 0 ? Theme.led.opacity(level) : .clear, radius: 4)
                }
                .frame(width: m(52), height: m(28))
                .scaleEffect(isDown || presentation.hardwarePressed ? 0.94 : 1)
                .offset(y: isDown || presentation.hardwarePressed ? m(1.5) : 0)
                .overlay {
                    RoundedRectangle(cornerRadius: m(6))
                        .stroke(Color.white.opacity(presentation.hardwarePressed ? 0.5 : 0), lineWidth: 1.5)
                }
                .animation(.easeOut(duration: 0.1), value: isDown || presentation.hardwarePressed)
                .modifier(PressGesture(isDown: $isDown, onPress: onPress, onRelease: onRelease))
            CellLabels(presentation: presentation)
        }
        .modifier(CellChrome(presentation: presentation))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.control.description) \(presentation.label ?? L10n.text("未分配"))")
        .accessibilityAddTraits(.isButton)
        .help(L10n.text("操作 \(presentation.control.shortName)"))
        .accessibilityAction {
            onPress()
            onRelease()
        }
    }
}

private struct PushButtonCell: View {
    let presentation: ControlPresentation
    @Environment(\.panelMetrics) private var m
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isDown = false

    var body: some View {
        HStack(spacing: m(3)) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(m.font(8, weight: .bold))
            Text(presentation.label ?? "PUSH")
                .font(m.font(8.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(presentation.label == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(presentation.accent))
        .frame(width: m(70), height: m(16))
        .background(
            isDown || presentation.hardwarePressed ? Color.white.opacity(0.25) : Color.black.opacity(0.3),
            in: Capsule()
        )
        .scaleEffect(isDown || presentation.hardwarePressed ? 0.94 : 1)
        .animation(.easeOut(duration: 0.1), value: isDown || presentation.hardwarePressed)
        .overlay {
            Capsule().stroke(
                presentation.isLearnTarget ? Theme.learn
                    : (presentation.isSelected ? Theme.selection : Color.white.opacity(0.06)),
                lineWidth: presentation.isLearnTarget ? 2 : 1
            )
        }
        .modifier(PressGesture(isDown: $isDown, onPress: onPress, onRelease: onRelease))
        .help(presentation.control.description)
        .accessibilityLabel(presentation.control.description)
        .accessibilityAddTraits(.isButton)
    }
}
