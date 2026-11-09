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
                detail = definition.formatted(value)
                accent = Theme.parameter
            }
        case let .agentPrimaryAction(slotID)?:
            label = "Agent \(slotID.rawValue)"
            if let slot = slot(slotID) {
                detail = slot.state.displayName
                accent = stateColor(slot.state)
            }
        case let .resetGroup(group)?:
            label = "复位 \(group)"
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

struct SurfacePanelView: View {
    @ObservedObject var model: ConsoleViewModel

    private let spacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    row("组\(model.visibleGroup)") {
                        ForEach(1...8, id: \.self) { index in
                            VStack(spacing: 4) {
                                knob(.pushEncoder(group: model.visibleGroup, index))
                                pushButton(.pushEncoderButton(group: model.visibleGroup, index))
                            }
                        }
                    }
                    divider
                    ForEach(1...2, id: \.self) { line in
                        row("B\(line)") {
                            ForEach(1...8, id: \.self) { index in pad(.button(row: line, index)) }
                        }
                    }
                    divider
                    ForEach(1...3, id: \.self) { line in
                        row("E\(line)") {
                            ForEach(1...8, id: \.self) { index in knob(.encoder(row: line, index)) }
                        }
                    }
                }
                sideColumn
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Theme.chassisTop, Theme.chassisBottom], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("BCR2000")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .tracking(2)
            Text(model.source == .mock ? "MOCK DEVICE" : "HARDWARE MIRROR")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(model.source == .mock ? Theme.parameter : Theme.selection)
                .background((model.source == .mock ? Theme.parameter : Theme.selection).opacity(0.14), in: Capsule())
            Spacer()
            Text(model.source == .mock
                ? "拖动旋钮 / 按下按键 = 模拟实体操作"
                : "拖动旋钮 / 按下按键 = 软件修改并回写硬件")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 34)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .padding(.top, 24)
            content()
        }
    }

    private var sideColumn: some View {
        VStack(spacing: 10) {
            Text("GROUP")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.fixed(34)), GridItem(.fixed(34))], spacing: 6) {
                ForEach(BCRLayout.encoderGroups, id: \.self) { group in
                    Button {
                        model.selectGroup(group)
                    } label: {
                        VStack(spacing: 3) {
                            Capsule()
                                .fill(group == model.visibleGroup ? Theme.led : Theme.ledOff)
                                .frame(width: 18, height: 3)
                                .shadow(color: group == model.visibleGroup ? Theme.led : .clear, radius: 3)
                            Text("\(group)")
                                .font(.caption.bold().monospacedDigit())
                        }
                        .frame(width: 34, height: 30)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .help(model.source == .mock
                ? "切换 Mock 设备的编码器组（与实体一样不发送 MIDI）"
                : "实体设备不会报告当前组；这里只切换显示。操作实体编码器时会自动跟随。")

            Spacer(minLength: 24)

            Text("USER")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(1...4, id: \.self) { index in pad(.userButton(index)) }
            }
        }
        .frame(width: 80)
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

    func body(content: Content) -> some View {
        content
            .frame(width: 74)
            .padding(.vertical, 5)
            .background(
                presentation.isSelected ? Theme.selection.opacity(0.14) : Color.black.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        presentation.isLearnTarget ? Theme.learn
                            : (presentation.isSelected ? Theme.selection : Color.white.opacity(0.04)),
                        lineWidth: presentation.isLearnTarget ? 2 : 1
                    )
            }
            .overlay(alignment: .topTrailing) {
                if !presentation.isBound {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .padding(4)
                        .help("此控件尚未学习 MIDI 身份")
                }
            }
    }
}

private struct CellLabels: View {
    let presentation: ControlPresentation

    var body: some View {
        VStack(spacing: 1) {
            Text(presentation.control.shortName)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(presentation.label ?? "未分配")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(presentation.label == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(presentation.accent))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(presentation.detail ?? "\(presentation.value)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 3)
    }
}

private struct KnobCell: View {
    let presentation: ControlPresentation
    let onTouch: () -> Void
    let onTurn: (Int) -> Void

    var body: some View {
        VStack(spacing: 3) {
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
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2.5, height: 11)
                    .offset(y: -12)
                    .rotationEffect(.degrees(-135 + Double(presentation.value) / 127 * 270))
                KnobValueInput(onTouch: onTouch, onDelta: onTurn)
            }
            .frame(width: 60, height: 60)
            CellLabels(presentation: presentation)
        }
        .modifier(CellChrome(presentation: presentation))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.control.description) \(presentation.label ?? "未分配")")
        .accessibilityValue(presentation.detail ?? "\(presentation.value)")
        .accessibilityAdjustableAction { direction in
            onTurn(direction == .increment ? 1 : -1)
        }
    }
}

private struct LEDRing: View {
    let value: UInt8
    private let count = 13

    var body: some View {
        let lit = Int((Double(value) / 127 * Double(count)).rounded())
        ZStack {
            ForEach(0..<count, id: \.self) { led in
                Circle()
                    .fill(led < lit ? Theme.led : Theme.ledOff)
                    .frame(width: 4, height: 4)
                    .shadow(color: led < lit ? Theme.led.opacity(0.9) : .clear, radius: 2.5)
                    .offset(y: -27)
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
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isDown = false

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: isDown ? [Color(white: 0.22), Color(white: 0.16)] : [Color(white: 0.30), Color(white: 0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)) }
                .overlay {
                    let level = Double(presentation.value) / 127
                    Capsule()
                        .fill(level > 0 ? Theme.led.opacity(0.35 + 0.65 * level) : Theme.ledOff)
                        .frame(width: 24, height: 4)
                        .shadow(color: level > 0 ? Theme.led.opacity(level) : .clear, radius: 4)
                }
                .frame(width: 52, height: 28)
                .scaleEffect(isDown ? 0.95 : 1)
                .modifier(PressGesture(isDown: $isDown, onPress: onPress, onRelease: onRelease))
            CellLabels(presentation: presentation)
        }
        .modifier(CellChrome(presentation: presentation))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.control.description) \(presentation.label ?? "未分配")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onPress()
            onRelease()
        }
    }
}

private struct PushButtonCell: View {
    let presentation: ControlPresentation
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isDown = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 8, weight: .bold))
            Text(presentation.label ?? "PUSH")
                .font(.system(size: 8.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(presentation.label == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(presentation.accent))
        .frame(width: 70, height: 16)
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
