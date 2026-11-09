import BCRAgentCore
import SwiftUI

struct MCPStatusButton: View {
    @ObservedObject var controller: MCPController
    @State private var showsSettings = false

    var body: some View {
        Button { showsSettings = true } label: {
            Label(controller.integrationTest ? "测试 · \(controller.status)" : controller.status, systemImage: "network")
                .font(.caption)
                .foregroundStyle(controller.error == nil ? Theme.parameter : .red)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("MCP 设置：\(controller.status)")
        .help("通用 MCP 接口设置")
        .sheet(isPresented: $showsSettings) { MCPSettingsView(controller: controller) }
    }
}

private struct MCPSettingsView: View {
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
                SectionTitle("MCP 控制接口", icon: "network")
                Spacer()
                Button("完成") { dismiss() }
            }
            Toggle("启用本机 MCP 服务", isOn: Binding(
                get: { controller.settings.enabled },
                set: { enabled in Task { await controller.setEnabled(enabled) } }
            ))
            HStack {
                Text(controller.endpoint).font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                Button("一键停止", role: .destructive) { controller.stop() }
                    .disabled(!controller.settings.enabled)
            }
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            Text("通用 MCP Streamable HTTP · 2026-07-28；兼容 2025-11-25 握手。仅监听 127.0.0.1。")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.integrationTest ? "隔离集成测试：使用内存测试凭据，不读取用户 Keychain。" : "凭据保存在 Keychain。")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("端口", value: $draft.port, format: .number)
                Toggle("参数写入（关闭时只读）", isOn: $draft.permissions.parameterWrite)
                Toggle("配置写入（修改分配和定义）", isOn: $draft.permissions.configurationWrite)
                TextField("每秒最多写入参数数", value: $draft.permissions.writesPerSecond, format: .number)
            }
            .formStyle(.columns)
            HStack {
                Button("应用设置") { Task { await controller.apply(draft) } }.buttonStyle(.borderedProminent)
                Button("复制 Token") { Task { await controller.copyToken() } }.disabled(!controller.settings.enabled || controller.isStarting)
                Button("复制连接命令") { Task { await controller.copyConnectionCommand() } }.disabled(!controller.settings.enabled || controller.isStarting)
            }
            Divider()
            Text("最近 100 次调用").font(.headline)
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
        .frame(width: 660, height: 600)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
