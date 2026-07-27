import BCRAgentCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var selectedPage: ConsolePage = .agents

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.055, green: 0.067, blue: 0.09),
                    Color(red: 0.09, green: 0.105, blue: 0.14),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    if let notice = model.notice {
                        noticeBanner(notice)
                    }
                    if selectedPage == .agents {
                        if !model.profile.isComplete || model.isQuickLearnEnabled {
                            quickLearnPanel
                        }
                        slotGrid
                        HStack(alignment: .top, spacing: 16) {
                            selectedSlotPanel
                            mappingPanel
                            diagnosticsPanel
                        }
                    } else {
                        HardwareMirrorView(model: model)
                    }
                }
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedPage) { _, page in
            if page == .hardware {
                model.pauseQuickLearn()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BCR AGENT CONSOLE")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .tracking(1.8)
                Text("Swift MVP · CoreMIDI ↔ Mock Agent")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("页面", selection: $selectedPage) {
                ForEach(ConsolePage.allCases) { page in
                    Label(page.title, systemImage: page.systemImage)
                        .tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Label(
                    model.connection.isConnected ? "BCR2000 已连接" : "等待 BCR2000",
                    systemImage: model.connection.isConnected
                        ? "cable.connector.horizontal"
                        : "cable.connector.slash"
                )
                .font(.headline)
                .foregroundStyle(model.connection.isConnected ? .green : .orange)

                Text(connectionDetail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var connectionDetail: String {
        if let source = model.connection.connectedSource,
           let destination = model.connection.connectedDestination {
            return "\(source) → App → \(destination)"
        }
        if let error = model.connection.lastError {
            return error
        }
        return "建议 BCR2000 使用 USB 模式 U-1"
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.cyan)
            Text(text)
                .font(.subheadline)
            Spacer()
            Button {
                model.clearNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.cyan.opacity(0.25))
        }
    }

    private var quickLearnPanel: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(model.profile.bindings.count) / 8)
                    .stroke(
                        Color.cyan,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(model.profile.bindings.count)/8")
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 5) {
                Text("BCR2000 快速学习")
                    .font(.headline)
                if model.isQuickLearnEnabled, let slot = model.nextLearnSlot {
                    Text("请按下要控制 Agent \(slot.rawValue) 的 momentary 按键")
                        .font(.title3.weight(.semibold))
                } else if !model.profile.isComplete {
                    Text("学习已暂停；开始后再按下一个 momentary 按键")
                        .font(.title3.weight(.semibold))
                } else {
                    Text("映射已完成，可重新学习")
                        .font(.title3.weight(.semibold))
                }
                Text("依次学习 8 个不同的 CC/Note 控件；软件随后会把每个 Mock 状态回写到同一 LED/灯环。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.profile.isComplete {
                Button(model.isQuickLearnEnabled ? "暂停学习" : "开始 / 继续学习") {
                    if model.isQuickLearnEnabled {
                        model.pauseQuickLearn()
                    } else {
                        model.enableQuickLearn()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isQuickLearnEnabled ? .orange : .blue)
            }
            Button("重置映射", role: .destructive) {
                model.resetMapping()
            }
            .buttonStyle(.bordered)
            .disabled(model.profile.bindings.isEmpty)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var slotGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(model.slots) { slot in
                Button {
                    model.selectedSlotID = slot.id
                } label: {
                    SlotCard(
                        slot: slot,
                        binding: model.profile.binding(for: slot.id),
                        isSelected: model.selectedSlotID == slot.id
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(primaryActionTitle(slot.state)) {
                        model.performPrimaryAction(slot.id)
                    }
                }
            }
        }
    }

    private var selectedSlotPanel: some View {
        let slot = model.selectedSlot
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("MOCK CONTROL", icon: "terminal")

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(slot.name)
                        .font(.title2.bold())
                    Text(slot.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StateBadge(state: slot.state)
            }

            ProgressView(value: slot.progress)
                .tint(stateColor(slot.state))

            HStack {
                Button(primaryActionTitle(slot.state)) {
                    model.performPrimaryAction(slot.id)
                }
                .buttonStyle(.borderedProminent)
                .tint(stateColor(slot.state))

                if slot.state == .waitingApproval {
                    Button("拒绝") {
                        model.decline(slot.id)
                    }
                    .buttonStyle(.bordered)
                }

                if slot.state == .running || slot.state == .queued {
                    Button("中断") {
                        model.interrupt(slot.id)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text("实体按键：空闲时启动、运行时中断、等待批准时批准。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .panelStyle()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var mappingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("MIDI MAP", icon: "slider.horizontal.3")

            ForEach(model.slots) { slot in
                HStack {
                    Text("\(slot.id.rawValue)")
                        .font(.caption.bold().monospacedDigit())
                        .frame(width: 18)
                    if let binding = model.profile.binding(for: slot.id) {
                        Text(binding.control.description)
                            .font(.caption.monospaced())
                    } else {
                        Text("未学习")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(stateColor(slot.state))
                        .frame(width: 7, height: 7)
                }
            }

            if model.profile.isComplete {
                Divider()
                .padding(.vertical, 2)
                Button("重新学习全部控件", role: .destructive) {
                    model.resetMapping()
                }
                .buttonStyle(.bordered)
            }
        }
        .panelStyle()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("MIDI MONITOR", icon: "waveform.path")

            if model.diagnostics.isEmpty {
                Text("转动旋钮或按下按键后，这里会显示原始 CC/Note。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.diagnostics.prefix(8).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .panelStyle()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .tracking(1)
    }

    private func primaryActionTitle(_ state: AgentRunState) -> String {
        switch state {
        case .waitingApproval: "批准"
        case .queued, .running: "中断"
        case .idle, .completed, .interrupted, .error: "启动 Mock"
        }
    }
}

private enum ConsolePage: String, CaseIterable, Identifiable {
    case agents
    case hardware

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Agent 控制台"
        case .hardware: "硬件镜像"
        }
    }

    var systemImage: String {
        switch self {
        case .agents: "square.grid.2x2"
        case .hardware: "dial.medium"
        }
    }
}

private struct SlotCard: View {
    let slot: AgentSlot
    let binding: ControllerBinding?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(format: "%02d", slot.id.rawValue))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(stateColor(slot.state))
                    .frame(width: 10, height: 10)
                    .shadow(color: stateColor(slot.state), radius: 5)
            }

            Text(slot.name)
                .font(.headline)
            Text(slot.state.displayName)
                .font(.title3.bold())
                .foregroundStyle(stateColor(slot.state))

            ProgressView(value: slot.progress)
                .tint(stateColor(slot.state))

            Text(binding?.control.description ?? "等待 MIDI 学习")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .background(
            isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(
                    isSelected ? stateColor(slot.state) : Color.white.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
    }
}

private struct StateBadge: View {
    let state: AgentRunState

    var body: some View {
        Text(state.displayName)
            .font(.caption.bold())
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(stateColor(state))
            .background(stateColor(state).opacity(0.12), in: Capsule())
    }
}

private struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08))
            }
    }
}

private extension View {
    func panelStyle() -> some View {
        modifier(PanelStyle())
    }
}

private func stateColor(_ state: AgentRunState) -> Color {
    switch state {
    case .idle: .gray
    case .queued: .blue
    case .running: .green
    case .waitingApproval: .orange
    case .completed: .cyan
    case .interrupted: .yellow
    case .error: .red
    }
}
