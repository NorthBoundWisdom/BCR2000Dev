import BCRAgentCore
import SwiftUI

struct OutputStatusButton: View {
    @ObservedObject var controller: OutputController
    @State private var showsSettings = false
    var body: some View {
        Button { showsSettings = true } label: {
            Label(
                controller.settings.enabled ? L10n
                    .text("输出 · \(controller.status == .ready ? L10n.text("运行") : L10n.text("受限"))") : L10n
                    .text("输出关闭"),
                systemImage: "arrow.up.forward.circle"
            )
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .tint(controller.status == .ready ? .green : .orange)
        .help(L10n.text("设置 OSC 输出、软限位、速度和 LED 来源"))
        .sheet(isPresented: $showsSettings) { OutputSettingsView(controller: controller) }
    }
}

struct OutputReadoutView: View {
    @ObservedObject var model: ConsoleViewModel
    @ObservedObject var controller: OutputController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.reason).foregroundStyle(controller.status == .ready ? .green : .orange)
            if let error = controller.error { Text(error).foregroundStyle(.red) }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(L10n.text("参数")); Text(L10n.text("目标")); Text(L10n.text("受限输出")); Text(L10n.text("实际回传"))
                }
                .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(controller.settings.limits) { limit in
                    if let definition = model.configuration.parameter(limit.id) {
                        GridRow {
                            Text(definition.name).lineLimit(1)
                            Text(model.engine.value(of: limit.id).map { definition.formatted($0) } ?? "—")
                            Text(controller.outputs[limit.id].map { definition.formatted(
                                $0,
                                snap: false,
                                minimumFractionDigits: 2
                            ) } ?? "—")
                            Text(controller.actual[limit.id].map { definition.formatted(
                                $0,
                                snap: false,
                                minimumFractionDigits: 2
                            ) } ?? "—")
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
            }
            Text(L10n.text("目标保留在软件参数中；受限输出经过安全门，实际回传来自对端。使能关闭时不发送运动值。"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct OutputSettingsView: View {
    @ObservedObject var controller: OutputController
    @State private var draft: OutputSettings
    @State private var confirmsLimits = false
    @Environment(\.dismiss) private var dismiss

    init(controller: OutputController) {
        self.controller = controller
        _draft = State(initialValue: controller.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(L10n.text("外部输出"), icon: "arrow.up.forward.circle")
                Spacer()
                Button(L10n.text("完成")) { dismiss() }
            }
            Text(controller.reason).foregroundStyle(controller.status == .ready ? .green : .orange)
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Form {
                TextField(L10n.text("目标地址"), text: $draft.host)
                TextField(L10n.text("端口"), value: $draft.port, format: .number)
            }
            .formStyle(.columns)
            Picker(L10n.text("使能参数"), selection: $draft.enableParameter) {
                ForEach(controller.session.engine.configuration.parameters.filter { $0.kind == .toggle }) {
                    Text($0.name).tag($0.id)
                }
            }
            HStack {
                Button(controller.settings.enabled ? L10n.text("停止输出") : L10n.text("启动输出")) {
                    if controller.settings.enabled { controller.stop() }
                    else { controller.apply(draft); if controller.error == nil { controller.start() } }
                }
                .buttonStyle(.borderedProminent)
                .help(L10n.text("启动或停止经过安全门的 OSC 输出"))
                Button(L10n.text("应用设置")) { controller.apply(draft) }
                Button(L10n.text("重新生成限位草稿…")) { confirmsLimits = true }
                    .confirmationDialog(L10n.text("按当前参数范围重建限位草稿？"), isPresented: $confirmsLimits) {
                        Button(L10n.text("重建草稿"), role: .destructive) {
                            draft.limits = OutputSettings.defaults(for: controller.session.engine.configuration).limits
                        }
                    } message: { Text(L10n.text("尚未应用的限位编辑会被替换，实际输出设置不会立即改变。")) }
            }
            Picker(L10n.text("LED 环显示"), selection: Binding(
                get: { controller.settings.ledSource },
                set: { controller.setLEDSource($0); draft.ledSource = controller.settings.ledSource }
            )) {
                Text(L10n.text("目标值")).tag(LEDFeedbackSource.target)
                Text(L10n.text("实际回传")).tag(LEDFeedbackSource.actual)
            }
            .pickerStyle(.segmented)
            Text(L10n.text("实际回传只投影到连续参数灯环，不覆盖目标。使能与触发按键 LED 始终反映软件目标。"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text(L10n.text("参数")); Text(L10n.text("软下限")); Text(L10n.text("软上限")); Text(L10n
                            .text("单周期最大变化")); Text(L10n.text("最大速度 / 秒"))
                    }
                    .font(.caption.bold())
                    ForEach($draft.limits) { $limit in
                        GridRow {
                            Text(controller.session.engine.configuration.parameter(limit.id)?.name ?? limit.id.rawValue)
                                .frame(width: 145, alignment: .leading).lineLimit(1)
                            numberField($limit.minimum, label: L10n.text("\(limit.id.rawValue) 软下限"))
                            numberField($limit.maximum, label: L10n.text("\(limit.id.rawValue) 软上限"))
                            numberField($limit.maximumChange, label: L10n.text("\(limit.id.rawValue) 单周期最大变化"))
                            numberField($limit.maximumVelocity, label: L10n.text("\(limit.id.rawValue) 最大速度"))
                        }
                    }
                }
            }
            Text(L10n.text("心跳与实际状态期限 300 ms；首次使能/重连从新鲜实际值起步。丢弃的过期/乱序回传：\(controller.droppedPackets)"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 850, height: 650)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func numberField(_ value: Binding<Double>, label: String) -> some View {
        TextField("", value: value, format: .number)
            .accessibilityLabel(label)
            .frame(width: 118)
            .textFieldStyle(.roundedBorder)
    }
}
