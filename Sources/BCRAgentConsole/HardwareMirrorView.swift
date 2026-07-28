import BCRAgentCore
import SwiftUI

struct HardwareMirrorView: View {
    @ObservedObject var model: ConsoleViewModel

    private let encoderRows = 4
    private let encodersPerRow = 8
    private let buttonColumns = [
        GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 12),
    ]

    private var controlChanges: [MIDIControlSnapshot] {
        model.surfaceControls.filter { $0.id.kind == .controlChange }
    }

    private var notes: [MIDIControlSnapshot] {
        model.surfaceControls.filter { $0.id.kind == .note }
    }

    private var displayedControlChanges: [MIDIControlSnapshot] {
        Array(controlChanges.prefix(encoderRows * encodersPerRow))
    }

    var body: some View {
        VStack(spacing: 16) {
            mirrorHeader
            statusStrip
            encoderPanel
            notePanel
            eventPanel
        }
    }

    private var mirrorHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Label("HARDWARE MIRROR", systemImage: "dial.medium.fill")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text("实时显示 BCR2000 输入与软件 feedback，卡片位置按首次收到控件的顺序固定。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.clearSurfaceMonitor()
            } label: {
                Label("清空实时状态", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            MirrorMetric(
                title: "DEVICE",
                value: model.connection.isConnected ? "ONLINE" : "OFFLINE",
                detail: model.connection.connectedSource ?? "等待 Port 1",
                color: model.connection.isConnected ? .green : .orange,
                icon: "cable.connector.horizontal"
            )
            MirrorMetric(
                title: "ROTARY / CC",
                value: "\(controlChanges.count) / 32",
                detail: "已发现的连续控制器",
                color: .cyan,
                icon: "dial.medium"
            )
            MirrorMetric(
                title: "NOTE BUTTONS",
                value: "\(notes.count)",
                detail: "已发现的 Note 控件",
                color: .purple,
                icon: "square.grid.3x3.fill"
            )
            MirrorMetric(
                title: "MIDI EVENTS",
                value: "\(model.surfaceControls.reduce(0) { $0 + $1.eventCount })",
                detail: "本次启动的双向事件",
                color: .blue,
                icon: "waveform.path.ecg"
            )
        }
    }

    private var encoderPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("32 ENCODER SURFACE", icon: "dial.medium")
                Spacer()
                HStack(spacing: 12) {
                    legend(color: .cyan, text: "IN 设备")
                    legend(color: .purple, text: "OUT 软件")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 9) {
                    HStack {
                        Text("BCR2000 · PORT 1")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(.cyan.opacity(0.82))
                        Spacer()
                        Text("4 BANKS × 8 ENCODERS")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    .padding(.horizontal, 12)

                    ForEach(0..<encoderRows, id: \.self) { row in
                        encoderRow(row)
                    }
                }
                .padding(12)
                .frame(minWidth: 870)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.035, green: 0.16, blue: 0.27),
                            Color(red: 0.02, green: 0.075, blue: 0.13),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.cyan.opacity(0.28), lineWidth: 1)
                }
            }

            Text(
                "清空后按实体面板顺序转动旋钮，控件会依次填入 4 × 8 硬件槽位；"
                    + "之后同一控件始终更新原位置。每个槽位显示实际 CC 与通道。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .mirrorPanel()
    }

    private func encoderRow(_ row: Int) -> some View {
        HStack(spacing: 7) {
            VStack(spacing: 2) {
                Text(row == 0 ? "PUSH" : "ROTARY")
                Text("\(row + 1)")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.56))
            .frame(width: 42)

            ForEach(0..<encodersPerRow, id: \.self) { column in
                let index = row * encodersPerRow + column
                if index < displayedControlChanges.count {
                    DAWKnob(
                        snapshot: displayedControlChanges[index],
                        slotIndex: index,
                        onAdjust: model.adjustSurfaceControl
                    )
                } else {
                    EmptyDAWKnob(index: index)
                }
            }
        }
        .padding(7)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08))
        }
    }

    private var notePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("NOTE / BUTTON SURFACE", icon: "square.grid.3x3.fill")

            if notes.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "hand.tap")
                        .font(.title2)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("尚未收到 Note 按键")
                            .font(.headline)
                        Text("按下发送 Note On/Off 的 BCR2000 按键后会在这里生成 pad。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
            } else {
                LazyVGrid(columns: buttonColumns, spacing: 12) {
                    ForEach(notes) { snapshot in
                        DAWButtonPad(snapshot: snapshot)
                    }
                }
            }
        }
        .mirrorPanel()
    }

    private var eventPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("LIVE MIDI EVENTS", icon: "waveform.path")

            if model.diagnostics.isEmpty {
                Text("转动旋钮或按下按键后，实时事件会显示在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 10)],
                    spacing: 8
                ) {
                    ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .background(
                                Color.black.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                }
            }
        }
        .mirrorPanel()
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .tracking(1)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct MirrorMetric: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(color)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.075))
        }
    }
}

private struct DAWKnob: View {
    let snapshot: MIDIControlSnapshot
    let slotIndex: Int
    let onAdjust: (MIDIControlID, Int) -> Void

    private var value: Double {
        snapshot.normalizedValue
    }

    private var accent: Color {
        snapshot.lastDirection == .input ? .cyan : .purple
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                ForEach(0..<11, id: \.self) { tick in
                    Capsule()
                        .fill(
                            Double(tick) / 10 <= value
                                ? accent.opacity(0.9)
                                : Color.white.opacity(0.13)
                        )
                        .frame(width: 2, height: 6)
                        .offset(y: -32)
                        .rotationEffect(.degrees(-135 + Double(tick) * 27))
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.22, green: 0.24, blue: 0.28),
                                Color(red: 0.075, green: 0.085, blue: 0.105),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    }
                    .shadow(color: accent.opacity(0.24), radius: 9)
                    .frame(width: 54, height: 54)

                Capsule()
                    .fill(accent)
                    .frame(width: 3, height: 23)
                    .offset(y: -10)
                    .rotationEffect(.degrees(-135 + value * 270))

                Circle()
                    .fill(Color.black.opacity(0.50))
                    .frame(width: 8, height: 8)

                Text("\(snapshot.displayedValue)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 17)
                    .overlay {
                        KnobValueInput { delta in
                            onAdjust(snapshot.id, delta)
                        }
                    }
                    .offset(y: 16)
            }
            .frame(width: 82, height: 72)

            Text("E\(String(format: "%02d", slotIndex + 1))  CC \(snapshot.id.number)")
                .font(.caption2.bold().monospaced())
                .lineLimit(1)

            HStack(spacing: 7) {
                valueBadge("IN", snapshot.inputValue, color: .cyan)
                valueBadge("OUT", snapshot.outputValue, color: .purple)
            }

            Text(
                "\(slotIndex < 8 ? "PUSH" : "ROTARY") · CH \(snapshot.id.channel + 1) · #\(snapshot.eventCount)"
            )
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .frame(width: 94)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(0.32))
        }
    }

    private func valueBadge(_ title: String, _ value: UInt8?, color: Color) -> some View {
        Text("\(title) \(value.map(String.init) ?? "---")")
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .foregroundStyle(value == nil ? Color.secondary : color)
    }
}

private struct EmptyDAWKnob: View {
    let index: Int

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                ForEach(0..<11, id: \.self) { tick in
                    Capsule()
                        .fill(Color.white.opacity(0.055))
                        .frame(width: 2, height: 5)
                    .offset(y: -32)
                        .rotationEffect(.degrees(-135 + Double(tick) * 27))
                }
                Circle()
                    .fill(Color.white.opacity(0.025))
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.06))
                    }
                    .frame(width: 54, height: 54)
                Text("--")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 82, height: 72)

            Text("E\(String(format: "%02d", index + 1)) · --")
                .font(.caption2.bold().monospaced())
                .foregroundStyle(.tertiary)
            Text("等待 CC 输入")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 2)
            Text("--")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .frame(width: 94)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.04))
        }
    }
}

private struct DAWButtonPad: View {
    let snapshot: MIDIControlSnapshot

    private var accent: Color {
        snapshot.lastDirection == .input ? .cyan : .purple
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.id.description)
                    .font(.caption.bold().monospaced())
                Spacer()
                Circle()
                    .fill(snapshot.displayedValue > 0 ? accent : Color.white.opacity(0.12))
                    .frame(width: 10, height: 10)
                    .shadow(
                        color: snapshot.displayedValue > 0 ? accent : .clear,
                        radius: 6
                    )
            }

            RoundedRectangle(cornerRadius: 8)
                .fill(
                    snapshot.displayedValue > 0
                        ? accent.opacity(0.45)
                        : Color.white.opacity(0.045)
                )
                .frame(height: 44)
                .overlay {
                    Text(snapshot.displayedValue > 0 ? "ON" : "OFF")
                        .font(.headline.monospaced())
                }

            HStack {
                Text("IN \(snapshot.inputValue.map(String.init) ?? "---")")
                    .foregroundStyle(.cyan)
                Spacer()
                Text("OUT \(snapshot.outputValue.map(String.init) ?? "---")")
                    .foregroundStyle(.purple)
            }
            .font(.system(size: 9, design: .monospaced))
        }
        .padding(11)
        .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(accent.opacity(0.28))
        }
    }
}

private struct MirrorPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.075))
            }
    }
}

private extension View {
    func mirrorPanel() -> some View {
        modifier(MirrorPanelStyle())
    }
}
