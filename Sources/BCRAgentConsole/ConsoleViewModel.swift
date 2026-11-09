import BCRAgentCore
import Combine
import Foundation

extension DeviceSource {
    var title: String {
        switch self {
        case .mock: "Mock 设备"
        case .hardware: "实体 BCR2000"
        }
    }
}

struct ConsoleNotice: Equatable {
    enum Level: Equatable {
        case info
        case warning
        case error
    }

    enum Action: Equatable {
        case switchToHardware
    }

    let level: Level
    let text: String
    var action: Action?
}

@MainActor
final class ConsoleViewModel: ObservableObject {
    private let session: SurfaceSession
    let mcp: MCPController
    var source: DeviceSource { session.source }
    var engine: SurfaceEngine { session.engine }
    var mock: MockBCR2000 { session.mock }
    var connection: MIDIConnectionSnapshot { session.connection }
    var events: [MonitorEvent] { session.events }
    var droppedFeedbackCount: Int { session.droppedFeedbackCount }
    @Published private(set) var slots: [AgentSlot]
    @Published private(set) var notice: ConsoleNotice?
    @Published private(set) var visibleGroup = 1
    @Published var selectedControl: BCRControlID? = .pushEncoder(group: 1, 1)
    /// Select whichever control was last touched on the device.
    @Published var followsTouch = true

    var agentMachine = AgentStateMachine()
    var mockTasks: [AgentSlotID: Task<Void, Never>] = [:]

    init(stores: ConsoleStores = .standard, startsMIDI: Bool = true,
         mcpCredentials: (any MCPCredentialStore)? = nil, integrationTest: Bool = false) {
        slots = AgentStateMachine().slots

        var notices: [String] = []
        var loadedMap = HardwareMap()
        do {
            if let map = try stores.hardwareMap.load() {
                if map.version == HardwareMap.currentVersion {
                    loadedMap = map
                } else {
                    notices.append("硬件映射版本 \(map.version) 已过期，请在实体模式下重新学习。")
                }
            }
        } catch {
            notices.append("硬件映射读取失败：\(error.localizedDescription)")
        }

        var configuration = SurfaceConfiguration.robotArmDemo()
        do {
            if let stored = try stores.configuration.load() {
                if stored.version == SurfaceConfiguration.currentVersion {
                    configuration = stored
                } else if stored.version == 1 {
                    configuration = stored
                    configuration.version = SurfaceConfiguration.currentVersion
                    notices.append("功能配置已从 v1 迁移到 v2；机械臂使能不允许 Agent 写入。")
                } else {
                    notices.append("功能配置版本 \(stored.version) 不受支持，已载入机械臂示例。")
                }
            }
        } catch {
            notices.append("功能配置读取失败，已载入机械臂示例：\(error.localizedDescription)")
        }

        let midi = CoreMIDIService()
        session = SurfaceSession(
            hardwareDevice: midi, hardwareMap: loadedMap, configuration: configuration,
            saveHardwareMap: { try stores.hardwareMap.save($0) },
            saveConfiguration: { try stores.configuration.save($0) }
        )
        mcp = MCPController(session: session, store: JSONFileStore(fileURL:
            stores.configuration.fileURL.deletingLastPathComponent().appending(path: "mcp-settings.json")),
            credentials: mcpCredentials ?? KeychainMCPCredentialStore(), integrationTest: integrationTest)
        session.onChange = { [weak self] in self?.objectWillChange.send() }
        session.onEvent = { [weak self] in self?.handleSessionEvent($0) }
        session.onTriggerAgent = { [weak self] in self?.performPrimaryAction($0) }
        if integrationTest {
            notice = ConsoleNotice(level: .info, text: "隔离集成测试：使用独立配置与内存凭据，不连接实体设备。")
        }
        if !notices.isEmpty {
            notice = ConsoleNotice(level: .error, text: notices.joined(separator: " "))
        }
        session.synchronize()
        Task { @MainActor [weak mcp] in await mcp?.restore() }
        guard startsMIDI else { return }
        do { try midi.start() }
        catch { notice = ConsoleNotice(level: .error, text: "CoreMIDI 启动失败：\(error.localizedDescription)") }
    }

    // MARK: Read model

    var configuration: SurfaceConfiguration {
        engine.configuration
    }

    var isLearning: Bool {
        engine.learnTarget != nil
    }

    var learnedCount: Int {
        engine.hardwareMap.boundCount
    }

    /// The value the virtual panel shows for a control.
    func displayValue(of control: BCRControlID) -> UInt8 {
        switch source {
        case .mock: mock.value(of: control)
        case .hardware: engine.state(of: control).value
        }
    }

    func slot(_ id: AgentSlotID) -> AgentSlot? {
        slots.first { $0.id == id }
    }

    // MARK: Device source

    func selectSource(_ newSource: DeviceSource) {
        session.selectSource(newSource)
    }

    func selectGroup(_ group: Int) {
        visibleGroup = min(max(group, 1), 4)
        session.selectGroup(visibleGroup)
    }

    // MARK: Panel interaction (mock: physical touch; hardware: software edit)

    func turn(_ control: BCRControlID, by delta: Int) {
        touch(control)
        session.turn(control, by: delta)
    }

    func press(_ control: BCRControlID) {
        touch(control)
        session.press(control)
    }

    func release(_ control: BCRControlID) {
        session.release(control)
    }

    /// Selects a touched control unless learning owns the selection.
    func touch(_ control: BCRControlID) {
        guard !isLearning else { return }
        selectedControl = control
    }

    // MARK: Parameters

    func setParameter(_ id: ParameterID, to value: Double) {
        session.setParameter(id, to: value)
    }

    func resetGroup(_ group: String) {
        session.resetGroup(group)
    }

    @discardableResult
    func createParameter(assigningTo control: BCRControlID? = nil) -> ParameterID? {
        do {
            return try session.createParameter(assigningTo: control)
        } catch {
            report(error)
            return nil
        }
    }

    func updateParameter(_ definition: ParameterDefinition) {
        do {
            notice = ConsoleNotice(level: .info, text: "参数“\(definition.name)”已更新。")
            try session.updateParameter(definition)
        } catch {
            report(error)
        }
    }

    func removeParameter(_ id: ParameterID) {
        session.removeParameter(id)
    }

    func restoreDemoConfiguration() {
        notice = ConsoleNotice(level: .info, text: "已恢复机械臂示例配置。")
        session.replaceConfiguration(.robotArmDemo())
    }

    // MARK: Assignments

    func setAssignment(_ assignment: ControlAssignment?, for control: BCRControlID) {
        do { try session.setAssignment(assignment, for: control) }
        catch { report(error) }
    }

    // MARK: Hardware map / learning

    func beginLearning(at control: BCRControlID) {
        guard session.beginLearning(at: control) else {
            notice = ConsoleNotice(level: .warning, text: "Mock 设备的预设已知，学习只用于实体 BCR2000。")
            return
        }
        selectedControl = control
        notice = ConsoleNotice(
            level: .info,
            text: "学习中：请操作实体 \(control.shortName)。完成后会自动跳到本区下一个未学习控件，可连续扫过整排。"
        )
    }

    func stopLearning() {
        session.stopLearning()
        notice = ConsoleNotice(level: .info, text: "学习已停止，已学习 \(learnedCount) / \(BCRLayout.allControls.count) 个控件。")
    }

    func unbind(_ control: BCRControlID) {
        guard source == .hardware else { return }
        session.unbind(control)
    }

    func resetHardwareMap() {
        guard source == .hardware else { return }
        notice = ConsoleNotice(level: .info, text: "实体映射已清空，请重新学习。")
        session.resetHardwareMap()
    }

    // MARK: Misc

    func clearMonitor() {
        session.clearMonitor()
    }

    func clearNotice() {
        notice = nil
    }

    func performNoticeAction(_ action: ConsoleNotice.Action) {
        switch action {
        case .switchToHardware:
            selectSource(.hardware)
        }
    }

    // MARK: Session presentation

    private func handleSessionEvent(_ event: SurfaceSessionEvent) {
        switch event {
        case let .sourceChanged(source):
            switch source {
            case .mock:
                notice = ConsoleNotice(level: .info, text: "已切换到 Mock 设备：在虚拟面板上拖动旋钮、按下按键即模拟实体操作。")
            case .hardware:
                notice = connection.isConnected
                    ? ConsoleNotice(level: .info, text: "已切换到实体 BCR2000，软件状态已整体回写。")
                    : ConsoleNotice(level: .warning, text: "已切换到实体模式，但尚未找到 BCR2000 Port 1。")
            }
        case let .connected(snapshot):
            if source == .hardware {
                notice = ConsoleNotice(level: .info, text: "已连接 \(snapshot.connectedSource ?? "BCR2000")，软件状态已整体回写。")
            } else {
                notice = ConsoleNotice(
                    level: .info,
                    text: "检测到 \(snapshot.connectedSource ?? "BCR2000")。当前仍在 Mock 模式，实体输入只记录不执行。",
                    action: .switchToHardware
                )
            }
        case let .touched(control):
            guard followsTouch else { return }
            selectedControl = control
            if control.section == .pushEncoder || control.section == .pushEncoderButton {
                selectGroup(control.row)
            }
        case let .learned(control, midi, next):
            selectedControl = next ?? control
            notice = ConsoleNotice(level: .info, text: next.map {
                "\(control.shortName) = \(midi)。下一个：请操作 \($0.shortName)。"
            } ?? "\(control.shortName) = \(midi)。本区已全部学习，学习结束。")
        case let .learnRejected(_, error):
            notice = ConsoleNotice(level: .warning, text: error.localizedDescription)
        case let .failed(operation, message):
            let prefix: String
            switch operation {
            case .feedback: prefix = "反馈发送失败"
            case .hardwareMapPersistence: prefix = "硬件映射保存失败"
            case .configurationPersistence: prefix = "功能配置保存失败"
            }
            notice = ConsoleNotice(level: .error, text: "\(prefix)：\(message)")
        }
    }

    /// Publishes agent slots and writes a changed state to the slot's LEDs.
    func applyAgentSlots(_ newSlots: [AgentSlot], changed slotID: AgentSlotID) {
        let previous = slot(slotID)?.state
        slots = newSlots
        guard let state = slot(slotID)?.state, state != previous else { return }
        session.setAgentFeedback(slotID, value: state.feedbackValue)
    }

    func report(_ error: Error) {
        notice = ConsoleNotice(level: .error, text: error.localizedDescription)
    }
}
