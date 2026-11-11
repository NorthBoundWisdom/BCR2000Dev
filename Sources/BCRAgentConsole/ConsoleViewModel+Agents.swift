import BCRAgentCore
import Foundation

/// Deterministic Mock Agent timeline. Agent state changes are written back to every control
/// assigned to the slot through `SurfaceEngine.setAgentFeedback`.
extension ConsoleViewModel {
    func performPrimaryAction(_ slotID: AgentSlotID) {
        if codex.backend == .codex { codex.perform(slotID); return }
        guard let slot = agentMachine.slot(slotID) else { return }
        switch slot.state {
        case .waitingApproval: approve(slotID)
        case .queued, .running: interrupt(slotID)
        case .idle, .completed, .interrupted, .error: start(slotID)
        }
    }

    func start(_ slotID: AgentSlotID) {
        if codex.backend == .codex { codex.start(slotID); return }
        guard let slot = agentMachine.slot(slotID), !slot.state.isActive else { return }
        mockTasks[slotID]?.cancel()
        do {
            try transition(slotID, to: .queued, progress: 0, statusText: L10n.text("Mock 任务已进入队列"))
        } catch {
            report(error)
            return
        }

        mockTasks[slotID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
                guard let self else { return }
                try self.transition(slotID, to: .running, progress: 0.08, statusText: L10n.text("分析工作区"))
                for (progress, text) in [
                    (0.20, L10n.text("读取项目上下文")),
                    (0.34, L10n.text("规划变更")),
                    (0.48, L10n.text("生成补丁")),
                    (0.58, L10n.text("准备执行受控操作"))
                ] {
                    try await Task.sleep(for: .milliseconds(550))
                    try Task.checkCancellation()
                    try self.updateProgress(slotID, progress: progress, statusText: text)
                }
                try self.transition(
                    slotID,
                    to: .waitingApproval,
                    progress: 0.60,
                    statusText: L10n.text("等待批准：运行 Mock 验证")
                )
                self.mockTasks[slotID] = nil
            } catch is CancellationError {
                return
            } catch {
                self?.report(error)
            }
        }
    }

    func interrupt(_ slotID: AgentSlotID) {
        if codex.backend == .codex { codex.interrupt(slotID); return }
        guard let slot = agentMachine.slot(slotID), slot.state.isActive else { return }
        mockTasks[slotID]?.cancel()
        mockTasks[slotID] = nil
        do {
            try transition(slotID, to: .interrupted, statusText: L10n.text("已由控制台中断"))
        } catch {
            report(error)
        }
    }

    func approve(_ slotID: AgentSlotID) {
        if codex.backend == .codex { codex.decide(slotID, approve: true); return }
        guard agentMachine.slot(slotID)?.state == .waitingApproval else { return }
        do {
            try transition(slotID, to: .running, progress: 0.64, statusText: L10n.text("批准通过，继续验证"))
        } catch {
            report(error)
            return
        }

        mockTasks[slotID] = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                for (progress, text) in [
                    (0.72, L10n.text("运行单元测试")),
                    (0.84, L10n.text("检查构建结果")),
                    (0.94, L10n.text("整理变更摘要"))
                ] {
                    try await Task.sleep(for: .milliseconds(600))
                    try Task.checkCancellation()
                    try self.updateProgress(slotID, progress: progress, statusText: text)
                }
                try await Task.sleep(for: .milliseconds(450))
                try self.transition(slotID, to: .completed, progress: 1, statusText: L10n.text("Mock 任务已完成"))
                self.mockTasks[slotID] = nil
            } catch is CancellationError {
                return
            } catch {
                self?.report(error)
            }
        }
    }

    func decline(_ slotID: AgentSlotID) {
        if codex.backend == .codex { codex.decide(slotID, approve: false); return }
        guard agentMachine.slot(slotID)?.state == .waitingApproval else { return }
        interrupt(slotID)
    }

    private func transition(
        _ slotID: AgentSlotID,
        to state: AgentRunState,
        progress: Double? = nil,
        statusText: String
    ) throws {
        try agentMachine.transition(slotID, to: state, progress: progress, statusText: statusText)
        publishAgent(slotID)
    }

    private func updateProgress(_ slotID: AgentSlotID, progress: Double, statusText: String) throws {
        try agentMachine.updateProgress(slotID, progress: progress, statusText: statusText)
        publishAgent(slotID)
    }

    private func publishAgent(_ slotID: AgentSlotID) {
        applyAgentSlots(agentMachine.slots, changed: slotID)
    }
}
