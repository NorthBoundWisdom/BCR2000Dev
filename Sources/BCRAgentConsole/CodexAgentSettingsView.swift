import BCRAgentCore
import SwiftUI

struct CodexAgentSettingsView: View {
    @ObservedObject var controller: CodexAgentController
    var body: some View {
        Form {
            Picker(L10n.text("Agent 后端"), selection: Binding(get: { controller.backend }, set: { value in
                Task { await controller.selectBackend(value) }
            })) {
                Text("Mock").tag(AgentBackend.mock)
                Text("Codex").tag(AgentBackend.codex)
            }
            HStack {
                TextField(L10n.text("可执行文件"), text: $controller.executable)
                Button(L10n.text("选择文件…")) { chooseExecutable() }
            }
            .disabled(controller.phase != .stopped && controller.phase != .failed)
            TextField(L10n.text("工作目录"), text: $controller.workspace)
                .disabled(controller.phase != .stopped && controller.phase != .failed)
            HStack {
                Button(L10n.text("连接")) { Task { await controller.connect() } }
                    .disabled(controller.backend != .codex || ![.stopped, .failed].contains(controller.phase))
                Button(L10n.text("全部停止")) { Task { await controller.stopAll() } }
                Text(controller.phase.title)
            }
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Picker(L10n.text("模型"), selection: $controller.modelID) {
                Text("—").tag("")
                ForEach(controller.models, id: \.id) { Text($0.displayName).tag($0.id) }
            }
            Picker(L10n.text("推理强度"), selection: $controller.effort) {
                Text(L10n.text("默认值")).tag("")
                ForEach(
                    controller.models.first(where: { $0.id == controller.modelID })?.supportedReasoningEfforts ?? [],
                    id: \.self
                ) {
                    Text($0).tag($0)
                }
            }
            Toggle(L10n.text("允许写入当前工作目录"), isOn: $controller.allowWorkspaceWrites)
            Text(L10n.text("默认只读；写入仅限所选目录。审批前请查看 Agent 页中的操作详情。"))
                .font(.caption).foregroundStyle(.secondary)
            TextField(L10n.text("任务内容"), text: $controller.prompt, axis: .vertical).lineLimit(3 ... 6)
            Button(L10n.text("保存设置")) { controller.savePreferences() }
            Text(L10n.text("设置不保存任务内容，重新打开后不会自动连接或启动任务。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("连接不会启动任务；从 Agent 页或绑定按键明确启动。"))
                .font(.caption)
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 680, height: 660)
        .preferredColorScheme(.dark)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in controller.selectExecutable(url) }
        }
    }
}

struct AgentBackendStatusView: View {
    @ObservedObject var controller: CodexAgentController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(controller.backend == .mock ? "Mock" : "Codex · \(controller.phase.title)")
                Spacer()
                if controller.backend == .codex {
                    Button(L10n.text("全部停止")) { Task { await controller.stopAll() } }
                }
            }
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red) }
            ForEach(controller.approvals) { approval in
                HStack(alignment: .top) {
                    Text("Agent \(approval.slotID.rawValue): \(approval.detail)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L10n.text("查看审批")) { controller.reviewApproval(approval.id) }
                    Button(L10n.text("拒绝")) { controller.rejectApproval(approval.id) }
                        .disabled(controller.respondingApprovals.contains(approval.id))
                }
            }
        }
    }
}

/// Keep an explicitly opened UI review attached to the main window across workspace tabs.
struct CodexApprovalPresentation: View {
    @ObservedObject var controller: CodexAgentController
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: Binding(
                get: { controller.reviewingApproval },
                set: { if $0 == nil { controller.dismissApprovalReview() } }
            )) { approval in
                CodexApprovalReviewView(controller: controller, approval: approval)
            }
    }
}

struct CodexApprovalReviewView: View {
    @ObservedObject var controller: CodexAgentController
    let approval: CodexPendingApproval
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Codex 审批详情")).font(.title2.bold())
            Text("Agent \(approval.slotID.rawValue) · \(approval.id.stringValue)").font(.caption.monospaced())
            Text(L10n.text("请求不会自动过期。请阅读操作详情，再明确批准或拒绝。"))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(approval.detail).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L10n.text("关闭")) { controller.dismissApprovalReview() }
                Button(L10n.text("中断")) { controller.interrupt(approval.slotID) }
                Spacer()
                Button(L10n.text("拒绝")) { controller.rejectApproval(approval.id) }
                    .disabled(controller.respondingApprovals.contains(approval.id))
                Button(L10n.text("批准此请求")) { controller.approveReviewedRequest(approval) }
                    .disabled(controller.respondingApprovals.contains(approval.id))
            }
        }
        .padding(24).frame(width: 660, height: 460)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onAppear { controller.markApprovalPresented(approval) }
    }
}

extension CodexConnectionPhase {
    var title: String {
        switch self {
        case .stopped: L10n.text("未连接")
        case .launching: L10n.text("启动")
        case .initializing: L10n.text("初始化")
        case .ready: L10n.text("已就绪")
        case .failed: L10n.text("错误")
        }
    }
}
