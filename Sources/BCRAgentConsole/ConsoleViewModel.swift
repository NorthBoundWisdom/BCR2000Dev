import BCRAgentCore
import Combine
import Foundation

@MainActor
final class ConsoleViewModel: ObservableObject {
    @Published private(set) var slots: [AgentSlot]
    @Published var selectedSlotID = AgentSlotID(1)
    @Published private(set) var connection = MIDIConnectionSnapshot()
    @Published private(set) var profile: ControllerProfile
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var surfaceControls: [MIDIControlSnapshot] = []
    @Published private(set) var notice: String?
    @Published var isQuickLearnEnabled: Bool

    private var stateMachine: AgentStateMachine
    private let profileStore: ControllerProfileStore
    private var midi: CoreMIDIService?
    private var mockTasks: [AgentSlotID: Task<Void, Never>] = [:]
    private var lastPhysicalActivation: [MIDIControlID: Date] = [:]
    private var recentFeedback: [MIDIControlID: (value: UInt8, sentAt: Date)] = [:]
    private var surfaceState = MIDISurfaceState()

    init(profileStore: ControllerProfileStore = ControllerProfileStore()) {
        self.profileStore = profileStore
        stateMachine = AgentStateMachine()
        slots = stateMachine.slots

        let loadedProfile: ControllerProfile
        do {
            loadedProfile = try profileStore.load()
        } catch {
            loadedProfile = ControllerProfile()
            notice = "控制器映射读取失败：\(error.localizedDescription)"
        }
        profile = loadedProfile
        isQuickLearnEnabled = false

        midi = CoreMIDIService(
            onMessages: { [weak self] messages in
                Task { @MainActor [weak self] in
                    self?.handleMIDI(messages)
                }
            },
            onConnection: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.handleConnection(snapshot)
                }
            }
        )

        do {
            try midi?.start()
        } catch {
            connection.lastError = error.localizedDescription
            notice = "CoreMIDI 启动失败：\(error.localizedDescription)"
        }
    }

    var selectedSlot: AgentSlot {
        slots.first { $0.id == selectedSlotID } ?? slots[0]
    }

    var nextLearnSlot: AgentSlotID? {
        profile.nextUnboundSlot
    }

    func start(_ slotID: AgentSlotID) {
        guard let slot = stateMachine.slot(slotID), !slot.state.isActive else {
            return
        }

        mockTasks[slotID]?.cancel()
        do {
            try transition(
                slotID,
                to: .queued,
                progress: 0,
                statusText: "Mock 任务已进入队列"
            )
        } catch {
            report(error)
            return
        }

        mockTasks[slotID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
                guard let self else { return }
                try self.transition(
                    slotID,
                    to: .running,
                    progress: 0.08,
                    statusText: "分析工作区"
                )

                let stages: [(Double, String)] = [
                    (0.20, "读取项目上下文"),
                    (0.34, "规划变更"),
                    (0.48, "生成补丁"),
                    (0.58, "准备执行受控操作"),
                ]
                for stage in stages {
                    try await Task.sleep(for: .milliseconds(550))
                    try Task.checkCancellation()
                    try self.updateProgress(
                        slotID,
                        progress: stage.0,
                        statusText: stage.1
                    )
                }

                try self.transition(
                    slotID,
                    to: .waitingApproval,
                    progress: 0.60,
                    statusText: "等待批准：运行 Mock 验证"
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
        guard let slot = stateMachine.slot(slotID), slot.state.isActive else {
            return
        }
        mockTasks[slotID]?.cancel()
        mockTasks[slotID] = nil
        do {
            try transition(
                slotID,
                to: .interrupted,
                statusText: "已由控制台中断"
            )
        } catch {
            report(error)
        }
    }

    func approve(_ slotID: AgentSlotID) {
        guard stateMachine.slot(slotID)?.state == .waitingApproval else {
            return
        }

        do {
            try transition(
                slotID,
                to: .running,
                progress: 0.64,
                statusText: "批准通过，继续验证"
            )
        } catch {
            report(error)
            return
        }

        mockTasks[slotID] = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let stages: [(Double, String)] = [
                    (0.72, "运行单元测试"),
                    (0.84, "检查构建结果"),
                    (0.94, "整理变更摘要"),
                ]
                for stage in stages {
                    try await Task.sleep(for: .milliseconds(600))
                    try Task.checkCancellation()
                    try self.updateProgress(
                        slotID,
                        progress: stage.0,
                        statusText: stage.1
                    )
                }
                try await Task.sleep(for: .milliseconds(450))
                try self.transition(
                    slotID,
                    to: .completed,
                    progress: 1,
                    statusText: "Mock 任务已完成"
                )
                self.mockTasks[slotID] = nil
            } catch is CancellationError {
                return
            } catch {
                self?.report(error)
            }
        }
    }

    func decline(_ slotID: AgentSlotID) {
        guard stateMachine.slot(slotID)?.state == .waitingApproval else {
            return
        }
        interrupt(slotID)
    }

    func performPrimaryAction(_ slotID: AgentSlotID) {
        guard let slot = stateMachine.slot(slotID) else {
            return
        }
        switch slot.state {
        case .waitingApproval:
            approve(slotID)
        case .queued, .running:
            interrupt(slotID)
        case .idle, .completed, .interrupted, .error:
            start(slotID)
        }
    }

    func resetMapping() {
        profile.reset()
        isQuickLearnEnabled = true
        persistProfile()
        notice = "快速学习已重置；请依次按下 8 个 momentary 按键。"
    }

    func enableQuickLearn() {
        isQuickLearnEnabled = true
        notice = "快速学习已开启。下一个控件将绑定到槽位 \(nextLearnSlot?.rawValue ?? 1)。"
    }

    func pauseQuickLearn() {
        guard isQuickLearnEnabled else {
            return
        }
        isQuickLearnEnabled = false
        notice = "快速学习已暂停；硬件镜像仍会继续记录所有 MIDI 状态。"
    }

    func clearNotice() {
        notice = nil
    }

    func clearSurfaceMonitor() {
        surfaceState.reset()
        surfaceControls = []
        diagnostics = []
    }

    func adjustSurfaceControl(_ control: MIDIControlID, by delta: Int) {
        guard control.kind == .controlChange, delta != 0 else {
            return
        }
        guard let snapshot = surfaceControls.first(where: { $0.id == control }) else {
            return
        }

        let boundedDelta = min(max(delta, -127), 127)
        let adjustedValue = UInt8(
            min(max(Int(snapshot.displayedValue) + boundedDelta, 0), 127)
        )
        guard adjustedValue != snapshot.displayedValue else {
            return
        }
        guard connection.connectedDestination != nil, let midi else {
            let message = "BCR2000 输出端口未连接，无法回写 CC \(control.number)。"
            connection.lastError = message
            notice = message
            appendDiagnostic("反馈失败：\(message)")
            return
        }

        let message = MIDI1UMPCodec.feedback(control: control, value: adjustedValue)
        do {
            try midi.send(message)
            recentFeedback[control] = (adjustedValue, .now)
            surfaceState.observe(message, direction: .output)
            surfaceControls = surfaceState.controls
            appendDiagnostic("UI \(message.diagnosticDescription)")
        } catch {
            connection.lastError = error.localizedDescription
            notice = "旋钮反馈失败：\(error.localizedDescription)"
            appendDiagnostic("反馈失败：\(error.localizedDescription)")
        }
    }

    private func handleConnection(_ snapshot: MIDIConnectionSnapshot) {
        let wasConnected = connection.isConnected
        connection = snapshot
        if snapshot.isConnected {
            if !wasConnected {
                notice = "已连接 \(snapshot.connectedSource ?? "BCR2000")，反馈发送到 \(snapshot.connectedDestination ?? "Port 1")。"
            }
            sendAllFeedback()
        } else if snapshot.lastError == nil {
            notice = "未找到完整的 BCR2000 输入/输出端点。"
        }
    }

    private func handleMIDI(_ messages: [MIDIVoiceMessage]) {
        for message in messages {
            appendDiagnostic(message.diagnosticDescription)
            surfaceState.observe(message, direction: .input)

            if isRecentFeedbackEcho(message) {
                continue
            }

            if isQuickLearnEnabled, !profile.isComplete, message.isPositiveActivation {
                if let learned = profile.learn(message.controlID) {
                    persistProfile()
                    selectedSlotID = learned.slotID
                    notice = "已将 \(learned.control.description) 绑定到槽位 \(learned.slotID.rawValue)。"
                    sendFeedback(for: learned.slotID)
                    if profile.isComplete {
                        isQuickLearnEnabled = false
                        notice = "8 个槽位映射完成，BCR2000 与 Mock 状态已联动。"
                        sendAllFeedback()
                    }
                }
                continue
            }

            guard
                message.isPositiveActivation,
                let binding = profile.binding(for: message.controlID),
                shouldAcceptPhysicalActivation(message.controlID)
            else {
                continue
            }

            selectedSlotID = binding.slotID
            performPrimaryAction(binding.slotID)
        }
        surfaceControls = surfaceState.controls
    }

    private func shouldAcceptPhysicalActivation(_ control: MIDIControlID) -> Bool {
        let now = Date()
        defer { lastPhysicalActivation[control] = now }
        guard let previous = lastPhysicalActivation[control] else {
            return true
        }
        return now.timeIntervalSince(previous) >= 0.25
    }

    private func isRecentFeedbackEcho(_ message: MIDIVoiceMessage) -> Bool {
        guard let feedback = recentFeedback[message.controlID] else {
            return false
        }
        return feedback.value == message.value
            && Date().timeIntervalSince(feedback.sentAt) < 0.18
    }

    private func transition(
        _ slotID: AgentSlotID,
        to state: AgentRunState,
        progress: Double? = nil,
        statusText: String
    ) throws {
        try stateMachine.transition(
            slotID,
            to: state,
            progress: progress,
            statusText: statusText
        )
        publish(slotID)
    }

    private func updateProgress(
        _ slotID: AgentSlotID,
        progress: Double,
        statusText: String
    ) throws {
        try stateMachine.updateProgress(
            slotID,
            progress: progress,
            statusText: statusText
        )
        publish(slotID)
    }

    private func publish(_ slotID: AgentSlotID) {
        slots = stateMachine.slots
        sendFeedback(for: slotID)
    }

    private func sendAllFeedback() {
        for slot in slots {
            sendFeedback(for: slot.id)
        }
    }

    private func sendFeedback(for slotID: AgentSlotID) {
        guard
            connection.connectedDestination != nil,
            let binding = profile.binding(for: slotID),
            let slot = stateMachine.slot(slotID)
        else {
            return
        }

        let value = slot.state.feedbackValue
        let message = MIDI1UMPCodec.feedback(control: binding.control, value: value)
        do {
            try midi?.send(message)
            recentFeedback[binding.control] = (value, .now)
            surfaceState.observe(message, direction: .output)
            surfaceControls = surfaceState.controls
        } catch {
            connection.lastError = error.localizedDescription
            appendDiagnostic("反馈失败：\(error.localizedDescription)")
        }
    }

    private func persistProfile() {
        do {
            try profileStore.save(profile)
        } catch {
            notice = "控制器映射保存失败：\(error.localizedDescription)"
        }
    }

    private func appendDiagnostic(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        diagnostics.insert("\(formatter.string(from: .now))  \(line)", at: 0)
        diagnostics = Array(diagnostics.prefix(12))
    }

    private func report(_ error: Error) {
        notice = error.localizedDescription
        appendDiagnostic("状态机错误：\(error.localizedDescription)")
    }
}
