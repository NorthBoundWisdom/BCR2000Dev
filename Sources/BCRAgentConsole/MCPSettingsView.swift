import BCRAgentCore
import SwiftUI

struct MCPStatusButton: View {
    @ObservedObject var controller: MCPController
    @State private var showsSettings = false

    var body: some View {
        Button { showsSettings = true } label: {
            Label(
                controller.integrationTest ? L10n.text("测试 · \(controller.status)") : controller.status,
                systemImage: "network"
            )
            .font(.caption)
            .foregroundStyle(controller.error == nil ? Theme.parameter : .red)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(L10n.text("MCP 设置：\(controller.status)"))
        .help(L10n.text("通用 MCP 接口设置"))
        .sheet(isPresented: $showsSettings) { MCPSettingsView(controller: controller) }
    }
}

struct MCPSettingsView: View {
    @ObservedObject var controller: MCPController
    @State private var draft: MCPSettings
    @Environment(\.dismiss) private var dismiss

    init(controller: MCPController) {
        self.controller = controller
        _draft = State(initialValue: controller.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionTitle(L10n.text("MCP 控制接口"), icon: "network")
                Spacer()
                Button(L10n.text("完成")) { dismiss() }
            }
            Toggle(L10n.text("启用本机 MCP 服务"), isOn: Binding(
                get: { controller.settings.enabled },
                set: { enabled in Task { await controller.setEnabled(enabled) } }
            ))
            HStack {
                Text(controller.endpoint).font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                Button(L10n.text("一键停止"), role: .destructive) { controller.stop() }
                    .disabled(!controller.settings.enabled)
            }
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            Text(L10n.text("通用 MCP Streamable HTTP · 2026-07-28；兼容 2025-11-25 握手。仅监听 127.0.0.1。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.integrationTest ? L10n.text("隔离集成测试：使用内存测试凭据，不读取用户 Keychain。") : L10n
                .text("凭据保存在 Keychain。"))
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField(L10n.text("端口"), value: $draft.port, format: .number)
                Toggle(L10n.text("参数写入（关闭时只读）"), isOn: $draft.permissions.parameterWrite)
                Toggle(L10n.text("配置写入（修改分配和定义）"), isOn: $draft.permissions.configurationWrite)
                Toggle(L10n.text("允许 Agent 启动和中断任务"), isOn: $draft.permissions.agentControl)
                Toggle(L10n.text("允许切换设备源"), isOn: $draft.permissions.deviceControl)
                TextField(L10n.text("每秒最多写入参数数"), value: $draft.permissions.writesPerSecond, format: .number)
            }
            .formStyle(.columns)
            HStack {
                Button(L10n.text("应用设置")) { Task { await controller.apply(draft) } }.buttonStyle(.borderedProminent)
                Button(L10n.text("复制 Token")) { Task { await controller.copyToken() } }
                    .disabled(!controller.settings.enabled || controller.isStarting)
                Button(L10n.text("复制连接命令")) { Task { await controller.copyConnectionCommand() } }
                    .disabled(!controller.settings.enabled || controller.isStarting)
            }
            Divider()
            Text(L10n.text("最近 100 次调用")).font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(controller.service.audit.reversed())) { call in
                        HStack(alignment: .top) {
                            Text(call.time, style: .time).foregroundStyle(.secondary)
                            Text(call.method).font(.body.monospaced())
                            Text(call.detail).foregroundStyle(call.succeeded ? Color.secondary : Color.red)
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
        }
        .padding(24)
        .frame(width: 700, height: 680)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
