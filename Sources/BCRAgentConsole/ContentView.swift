import BCRAgentCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            if let notice = model.notice {
                NoticeBanner(notice: notice, model: model)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
            Divider()
            HStack(spacing: 0) {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 16) {
                        SurfacePanelView(model: model)
                        WorkspaceTabsView(model: model)
                    }
                    .padding(18)
                    .frame(minWidth: 860)
                }
                Divider()
                ControlInspectorView(model: model)
                    .frame(width: 330)
            }
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}

private struct HeaderBar: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BCR CONSOLE")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .tracking(1.6)
                Text(model.configuration.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Picker("设备", selection: Binding(get: { model.source }, set: { model.selectSource($0) })) {
                ForEach(DeviceSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            Spacer()

            if let target = model.engine.learnTarget {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                        .symbolEffect(.pulse)
                    Text("学习中：请操作实体 \(target.shortName)")
                        .font(.callout.bold())
                    Button("停止") { model.stopLearning() }
                        .controlSize(.small)
                }
                .foregroundStyle(Theme.learn)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.learn.opacity(0.12), in: Capsule())
            }

            Toggle("跟随触碰", isOn: $model.followsTouch)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("操作设备上的控件时自动在检查器中选中它")

            DeviceStatus(model: model)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

private struct DeviceStatus: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        let (title, detail, color, icon) = status
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.bold()).foregroundStyle(color)
                Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360, alignment: .trailing)
    }

    private var status: (String, String, Color, String) {
        let hardware = model.connection.isConnected
            ? "\(model.connection.connectedSource ?? "BCR2000") 在线"
            : (model.connection.lastError ?? "未找到 BCR2000 Port 1（建议 USB 模式 U-1）")
        switch model.source {
        case .mock:
            return (
                "Mock 设备运行中",
                "收 \(model.mock.receivedCount) · 发 \(model.mock.sentCount) · 实体：\(hardware)",
                Theme.parameter,
                "cpu"
            )
        case .hardware:
            let dropped = model.droppedFeedbackCount > 0 ? " · \(model.droppedFeedbackCount) 条反馈未发送" : ""
            return (
                model.connection.isConnected ? "BCR2000 已连接" : "BCR2000 未连接",
                hardware + dropped,
                model.connection.isConnected ? .green : .orange,
                model.connection.isConnected ? "cable.connector.horizontal" : "cable.connector.slash"
            )
        }
    }
}

private struct NoticeBanner: View {
    let notice: ConsoleNotice
    @ObservedObject var model: ConsoleViewModel

    private var color: Color {
        switch notice.level {
        case .info: .cyan
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.level == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(notice.text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            if notice.action == .switchToHardware {
                Button("切换到实体") { model.performNoticeAction(.switchToHardware) }
                    .controlSize(.small)
            }
            Button {
                model.clearNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.25)) }
    }
}
