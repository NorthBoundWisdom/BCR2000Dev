import BCRAgentCore
import SwiftUI

struct MIDIEndpointSettingsView: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var draft: MIDIEndpointSelection
    @Environment(\.dismiss) private var dismiss

    init(model: ConsoleViewModel) {
        self.model = model
        _draft = State(initialValue: model.endpointSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionTitle("实体 MIDI 端口", icon: "cable.connector")
                Spacer()
                Button("完成") { dismiss() }
            }
            Text("自动模式使用 BCR2000 Port 1。手动可选 USB-MIDI 或其他接口；所选端口缺失时不改用其他端口。")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Picker("输入端口", selection: Binding(
                    get: { draft.sourceID ?? 0 }, set: { draft.sourceID = $0 == 0 ? nil : $0 }
                )) {
                    Text("自动 · Port 1").tag(Int32(0))
                    ForEach(model.connection.sourceEndpoints) {
                        Text($0.availabilityKnown ? $0.name : "\($0.name)（状态未知）").tag($0.id)
                    }
                    if let id = draft.sourceID, !model.connection.sourceEndpoints.contains(where: { $0.id == id }) {
                        Text("所选输入已断开").tag(id)
                    }
                }
                Picker("输出端口", selection: Binding(
                    get: { draft.destinationID ?? 0 }, set: { draft.destinationID = $0 == 0 ? nil : $0 }
                )) {
                    Text("自动 · Port 1").tag(Int32(0))
                    ForEach(model.connection.destinationEndpoints) {
                        Text($0.availabilityKnown ? $0.name : "\($0.name)（状态未知）").tag($0.id)
                    }
                    if let id = draft.destinationID,
                       !model.connection.destinationEndpoints.contains(where: { $0.id == id })
                    {
                        Text("所选输出已断开").tag(id)
                    }
                }
            }
            .formStyle(.columns)
            Text("当前输入：\(model.connection.connectedSource ?? "未连接")")
            Text("当前输出：\(model.connection.connectedDestination ?? "未连接")")
            if let error = model.connection.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if !model.canConfigureMIDI {
                Text("隔离测试未启用实体 MIDI。").foregroundStyle(.secondary)
            }
            HStack {
                Button("恢复自动选择") { draft = .init() }
                Spacer()
                Button("应用端口") { model.applyEndpointSelection(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConfigureMIDI)
                    .help("保存并重新连接所选 MIDI 输入与输出端口")
            }
            Text("端口选择保留当前实体映射；换设备或预设后需重新学习。")
                .font(.caption).foregroundStyle(.secondary)
            Text("改变端口会停止已启动的 OSC 输出，需要重新确认使能后手动启动。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 540, height: 440)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
