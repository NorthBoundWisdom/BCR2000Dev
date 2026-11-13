import BCRAgentCore
import SwiftUI

/// Device page: the physical MIDI ports and how feedback to the device is scheduled.
struct DeviceSettingsView: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        Form {
            MIDIEndpointSettingsSection(model: model)
            FeedbackSettingsSection(controller: model.feedbackSettings)
        }
        .formStyle(.grouped)
        .padding(12)
        .settingsPage()
    }
}

struct MIDIEndpointSettingsSection: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var draft: MIDIEndpointSelection
    @State private var applied = 0

    init(model: ConsoleViewModel) {
        self.model = model
        _draft = State(initialValue: model.endpointSelection)
    }

    private var dirty: Bool { draft != model.endpointSelection }

    var body: some View {
        Section {
            Text(L10n.text("自动模式优先 BCR2000 Port 1，没有 Port 1 时使用唯一的 BCR2000 端口。手动可选 USB-MIDI 或其他接口；所选端口缺失时不改用其他端口。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(L10n.text("输入端口"), selection: Binding(
                get: { draft.sourceID ?? 0 }, set: { draft.sourceID = $0 == 0 ? nil : $0 }
            )) {
                Text(L10n.text("自动 · Port 1")).tag(Int32(0))
                ForEach(model.connection.sourceEndpoints) {
                    Text($0.availabilityKnown ? $0.name : L10n.text("\($0.name)（状态未知）")).tag($0.id)
                }
                if let id = draft.sourceID, !model.connection.sourceEndpoints.contains(where: { $0.id == id }) {
                    Text(L10n.text("所选输入已断开")).tag(id)
                }
            }
            Picker(L10n.text("输出端口"), selection: Binding(
                get: { draft.destinationID ?? 0 }, set: { draft.destinationID = $0 == 0 ? nil : $0 }
            )) {
                Text(L10n.text("自动 · Port 1")).tag(Int32(0))
                ForEach(model.connection.destinationEndpoints) {
                    Text($0.availabilityKnown ? $0.name : L10n.text("\($0.name)（状态未知）")).tag($0.id)
                }
                if let id = draft.destinationID,
                   !model.connection.destinationEndpoints.contains(where: { $0.id == id })
                {
                    Text(L10n.text("所选输出已断开")).tag(id)
                }
            }
            Text(L10n.text("当前输入：\(model.connection.connectedSource ?? L10n.text("未连接"))"))
            Text(L10n.text("当前输出：\(model.connection.connectedDestination ?? L10n.text("未连接"))"))
            if let error = model.connection.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if !model.canConfigureMIDI {
                Text(L10n.text("隔离测试未启用实体 MIDI。")).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text("恢复自动选择")) { draft = .init() }
                ApplyStatusLabel(dirty: dirty, applied: applied)
                Spacer()
                Button(L10n.text("应用端口")) {
                    model.applyEndpointSelection(draft)
                    if model.endpointSelection == draft, !model.endpointSettingsNeedRepair { applied += 1 }
                }
                .buttonStyle(.borderedProminent)
                // Re-applying the same choice is still needed to repair unreadable saved settings.
                .disabled(!model.canConfigureMIDI || (!dirty && !model.endpointSettingsNeedRepair))
                .help(L10n.text("保存并重新连接所选 MIDI 输入与输出端口"))
            }
            Text(L10n.text("端口选择保留当前实体映射；换设备或预设后需重新学习。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("改变端口会停止已启动的 OSC 输出，需要重新确认使能后手动启动。"))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label(L10n.text("实体 MIDI 端口"), systemImage: "cable.connector")
        }
        .onAppear { draft = model.endpointSelection }
        // The selection can also change through the MCP endpoint tool while this page is open.
        .onChange(of: model.endpointSelection) { _, selection in draft = selection }
    }
}
