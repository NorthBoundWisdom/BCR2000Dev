import BCRAgentCore
import SwiftUI

/// Everything the panel needs to draw one physical control.
struct ControlPresentation {
    let control: BCRControlID
    let value: UInt8
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
                    row(L10n.text("组\(model.visibleGroup)")) {
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
                .padding(.horizontal, m(7))
                .padding(.vertical, m(3))
                .foregroundStyle(model.source == .mock ? Theme.parameter : Theme.selection)
                .background((model.source == .mock ? Theme.parameter : Theme.selection).opacity(0.14), in: Capsule())
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

    private var sideColumn: some View {
        VStack(spacing: m(10)) {
            Text("GROUP")
                .font(m.font(8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.fixed(m(34))), GridItem(.fixed(m(34)))], spacing: m(6)) {
                ForEach(BCRLayout.encoderGroups, id: \.self) { group in
                    Button {
                        model.selectGroup(group)
                    } label: {
                        VStack(spacing: m(3)) {
                            Capsule()
                                .fill(group == model.visibleGroup ? Theme.led : Theme.ledOff)
                                .frame(width: m(18), height: m(3))
                                .shadow(color: group == model.visibleGroup ? Theme.led : .clear, radius: 3)
                            Text("\(group)")
                                .font(m.font(10, weight: .bold).monospacedDigit())
                        }
                        .frame(width: m(34), height: m(30))
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: m(6)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .help(model.source == .mock
                ? L10n.text("切换 Mock 设备的编码器组（与实体一样不发送 MIDI）")
                : L10n.text("实体设备不会报告当前组；这里只切换显示。操作实体编码器时会自动跟随。"))

            Spacer(minLength: m(24))

            Text("USER")
                .font(m.font(8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(spacing: m(6)) {
                ForEach(1 ... 4, id: \.self) { index in pad(.userButton(index)) }
            }
        }
        .frame(width: m(80))
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
                LEDRing(value: presentation.value)
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
    let value: UInt8
    @Environment(\.panelMetrics) private var m
    private let count = 13

    var body: some View {
        let lit = Int((Double(value) / 127 * Double(count)).rounded())
        ZStack {
            ForEach(0 ..< count, id: \.self) { led in
                Circle()
                    .fill(led < lit ? Theme.led : Theme.ledOff)
                    .frame(width: m(4), height: m(4))
                    .shadow(color: led < lit ? Theme.led.opacity(0.9) : .clear, radius: 2.5)
                    .offset(y: m(-27))
                    .rotationEffect(.degrees(-135 + Double(led) * 270 / Double(count - 1)))
            }
        }
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
                        colors: isDown ? [Color(white: 0.22), Color(white: 0.16)] : [
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
                .scaleEffect(isDown ? 0.95 : 1)
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
        .background(isDown ? Color.white.opacity(0.16) : Color.black.opacity(0.3), in: Capsule())
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
