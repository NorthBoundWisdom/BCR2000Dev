import BCRAgentCore
import Combine
import Foundation

enum DeviceSource: String, CaseIterable, Identifiable, Sendable {
    /// Built-in behavioural model of the device; the virtual panel acts as its physical surface.
    case mock
    /// The USB BCR2000 on Port 1; the virtual panel is a software-side mirror.
    case hardware

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mock: "Mock 设备"
        case .hardware: "实体 BCR2000"
        }
    }
}

struct MonitorEvent: Identifiable, Equatable {
    let id: Int
    let time: Date
    let direction: MIDIObservationDirection
    let source: DeviceSource
    let message: MIDIVoiceMessage
    let control: BCRControlID?
    /// Hardware input that arrived while the mock was the active device.
    let ignored: Bool
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
    @Published private(set) var source: DeviceSource = .mock
    @Published private(set) var engine: SurfaceEngine
    @Published private(set) var mock = MockBCR2000()
    @Published private(set) var slots: [AgentSlot]
    @Published private(set) var connection = MIDIConnectionSnapshot()
    @Published private(set) var events: [MonitorEvent] = []
    @Published private(set) var notice: ConsoleNotice?
    /// Feedback messages that could not be sent because the hardware output was unavailable.
    @Published private(set) var droppedFeedbackCount = 0
    @Published private(set) var visibleGroup = 1
    @Published var selectedControl: BCRControlID? = .pushEncoder(group: 1, 1)
    /// Select whichever control was last touched on the device.
    @Published var followsTouch = true

    var agentMachine = AgentStateMachine()
    var mockTasks: [AgentSlotID: Task<Void, Never>] = [:]

    private var hardwareMap: HardwareMap
    private let stores: ConsoleStores
    private var midi: CoreMIDIService?
    private var nextEventID = 0

    init(stores: ConsoleStores = .standard, startsMIDI: Bool = true) {
        self.stores = stores
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
                } else {
                    notices.append("功能配置版本 \(stored.version) 不受支持，已载入机械臂示例。")
                }
            }
        } catch {
            notices.append("功能配置读取失败，已载入机械臂示例：\(error.localizedDescription)")
        }

        hardwareMap = loadedMap
        engine = SurfaceEngine(hardwareMap: .mockPreset(), configuration: configuration)
        if !notices.isEmpty {
            notice = ConsoleNotice(level: .error, text: notices.joined(separator: " "))
        }
        perform(engine.fullFeedback())

        guard startsMIDI else { return }
        midi = CoreMIDIService(
            onMessages: { [weak self] messages in
                Task { @MainActor [weak self] in
                    self?.handleHardwareMessages(messages)
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
            notice = ConsoleNotice(level: .error, text: "CoreMIDI 启动失败：\(error.localizedDescription)")
        }
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
        guard newSource != source else { return }
        source = newSource
        engine.replaceHardwareMap(hardwareMap(for: newSource))
        droppedFeedbackCount = 0
        perform(engine.fullFeedback())
        switch newSource {
        case .mock:
            notice = ConsoleNotice(level: .info, text: "已切换到 Mock 设备：在虚拟面板上拖动旋钮、按下按键即模拟实体操作。")
        case .hardware:
            notice = connection.isConnected
                ? ConsoleNotice(level: .info, text: "已切换到实体 BCR2000，软件状态已整体回写。")
                : ConsoleNotice(level: .warning, text: "已切换到实体模式，但尚未找到 BCR2000 Port 1。")
        }
    }

    func selectGroup(_ group: Int) {
        visibleGroup = min(max(group, 1), 4)
        mock.activeGroup = visibleGroup
    }

    // MARK: Panel interaction (mock: physical touch; hardware: software edit)

    func turn(_ control: BCRControlID, by delta: Int) {
        touch(control)
        switch source {
        case .mock:
            if let message = mock.turn(control, by: delta) {
                receiveFromDevice(message)
            }
        case .hardware:
            perform(engine.adjust(control, by: delta))
        }
    }

    func press(_ control: BCRControlID) {
        touch(control)
        switch source {
        case .mock:
            if let message = mock.press(control) {
                receiveFromDevice(message)
            }
        case .hardware:
            perform(engine.press(control, isDown: true))
        }
    }

    func release(_ control: BCRControlID) {
        switch source {
        case .mock:
            if let message = mock.release(control) {
                receiveFromDevice(message)
            }
        case .hardware:
            perform(engine.press(control, isDown: false))
        }
    }

    /// Selects a touched control unless learning owns the selection.
    func touch(_ control: BCRControlID) {
        guard !isLearning else { return }
        selectedControl = control
    }

    // MARK: Parameters

    func setParameter(_ id: ParameterID, to value: Double) {
        perform(engine.setParameter(id, to: value))
    }

    func resetGroup(_ group: String) {
        perform(engine.resetGroup(group))
    }

    @discardableResult
    func createParameter(assigningTo control: BCRControlID? = nil) -> ParameterID? {
        let id = configuration.makeParameterID()
        let number = id.rawValue.split(separator: ".").last.map(String.init) ?? ""
        let definition = control.map { !$0.isContinuous } ?? false
            ? ParameterDefinition(id: id, name: "开关 \(number)", group: "自定义", minimum: 0, maximum: 1, kind: .toggle)
            : ParameterDefinition(id: id, name: "参数 \(number)", group: "自定义", minimum: 0, maximum: 127)
        do {
            try engine.addParameter(definition)
            if let control {
                perform(try engine.assign(ControlAssignment(control: control, target: .parameter(id))))
            }
            persistConfiguration()
            return id
        } catch {
            report(error)
            return nil
        }
    }

    func updateParameter(_ definition: ParameterDefinition) {
        do {
            perform(try engine.updateParameter(definition))
            persistConfiguration()
            notice = ConsoleNotice(level: .info, text: "参数“\(definition.name)”已更新。")
        } catch {
            report(error)
        }
    }

    func removeParameter(_ id: ParameterID) {
        engine.removeParameter(id)
        persistConfiguration()
    }

    func restoreDemoConfiguration() {
        engine.replaceConfiguration(.robotArmDemo())
        for slot in slots {
            _ = engine.setAgentFeedback(slot.id, value: slot.state.feedbackValue)
        }
        perform(engine.fullFeedback())
        persistConfiguration()
        notice = ConsoleNotice(level: .info, text: "已恢复机械臂示例配置。")
    }

    // MARK: Assignments

    func setAssignment(_ assignment: ControlAssignment?, for control: BCRControlID) {
        guard let assignment else {
            engine.clearAssignment(for: control)
            persistConfiguration()
            return
        }
        do {
            perform(try engine.assign(assignment))
            persistConfiguration()
        } catch {
            report(error)
        }
    }

    // MARK: Hardware map / learning

    func beginLearning(at control: BCRControlID) {
        guard source == .hardware else {
            notice = ConsoleNotice(level: .warning, text: "Mock 设备的预设已知，学习只用于实体 BCR2000。")
            return
        }
        engine.beginLearning(control)
        selectedControl = control
        notice = ConsoleNotice(
            level: .info,
            text: "学习中：请操作实体 \(control.shortName)。完成后会自动跳到本区下一个未学习控件，可连续扫过整排。"
        )
    }

    func stopLearning() {
        engine.stopLearning()
        notice = ConsoleNotice(level: .info, text: "学习已停止，已学习 \(learnedCount) / \(BCRLayout.allControls.count) 个控件。")
    }

    func unbind(_ control: BCRControlID) {
        guard source == .hardware else { return }
        engine.unbind(control)
        persistHardwareMap()
    }

    func resetHardwareMap() {
        guard source == .hardware else { return }
        engine.resetHardwareMap()
        persistHardwareMap()
        notice = ConsoleNotice(level: .info, text: "实体映射已清空，请重新学习。")
    }

    // MARK: Misc

    func clearMonitor() {
        events.removeAll()
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

    // MARK: Effect pipeline

    func perform(_ effects: [SurfaceEffect]) {
        for effect in effects {
            switch effect {
            case let .send(message):
                transmit(message)
            case let .triggerAgent(slot):
                performPrimaryAction(slot)
            case let .learned(control, midi):
                persistHardwareMap()
                if let next = engine.learnTarget {
                    selectedControl = next
                    notice = ConsoleNotice(level: .info, text: "\(control.shortName) = \(midi)。下一个：请操作 \(next.shortName)。")
                } else {
                    selectedControl = control
                    notice = ConsoleNotice(level: .info, text: "\(control.shortName) = \(midi)。本区已全部学习，学习结束。")
                }
            case let .learnRejected(_, error):
                notice = ConsoleNotice(level: .warning, text: error.localizedDescription)
            case .unmappedInput:
                break // Shown in the MIDI monitor as an unmapped event.
            }
        }
    }

    private func receiveFromDevice(_ message: MIDIVoiceMessage) {
        let control = engine.hardwareMap.control(for: message.controlID)
        log(.input, message, control: control, ignored: false)
        if followsTouch, !isLearning, let control {
            selectedControl = control
            if control.section == .pushEncoder || control.section == .pushEncoderButton {
                selectGroup(control.row)
            }
        }
        perform(engine.handleInput(message))
    }

    private func transmit(_ message: MIDIVoiceMessage) {
        let control = engine.hardwareMap.control(for: message.controlID)
        log(.output, message, control: control, ignored: false)
        switch source {
        case .mock:
            mock.receive(message)
        case .hardware:
            guard let midi, connection.connectedDestination != nil else {
                droppedFeedbackCount += 1
                return
            }
            do {
                try midi.send(message)
            } catch {
                droppedFeedbackCount += 1
                connection.lastError = error.localizedDescription
                notice = ConsoleNotice(level: .error, text: "反馈发送失败：\(error.localizedDescription)")
            }
        }
    }

    private func handleHardwareMessages(_ messages: [MIDIVoiceMessage]) {
        for message in messages {
            guard source == .hardware else {
                log(.input, message, control: hardwareMap.control(for: message.controlID), ignored: true)
                continue
            }
            receiveFromDevice(message)
        }
    }

    private func handleConnection(_ snapshot: MIDIConnectionSnapshot) {
        let wasConnected = connection.isConnected
        connection = snapshot
        guard snapshot.isConnected, !wasConnected else { return }
        switch source {
        case .hardware:
            droppedFeedbackCount = 0
            perform(engine.fullFeedback())
            notice = ConsoleNotice(level: .info, text: "已连接 \(snapshot.connectedSource ?? "BCR2000")，软件状态已整体回写。")
        case .mock:
            notice = ConsoleNotice(
                level: .info,
                text: "检测到 \(snapshot.connectedSource ?? "BCR2000")。当前仍在 Mock 模式，实体输入只记录不执行。",
                action: .switchToHardware
            )
        }
    }

    private func hardwareMap(for source: DeviceSource) -> HardwareMap {
        switch source {
        case .mock: mock.preset
        case .hardware: hardwareMap
        }
    }

    private func log(_ direction: MIDIObservationDirection, _ message: MIDIVoiceMessage, control: BCRControlID?, ignored: Bool) {
        nextEventID += 1
        events.append(
            MonitorEvent(
                id: nextEventID,
                time: .now,
                direction: direction,
                source: ignored ? .hardware : source,
                message: message,
                control: control,
                ignored: ignored
            )
        )
        if events.count > 300 {
            events.removeFirst(events.count - 300)
        }
    }

    private func persistHardwareMap() {
        guard source == .hardware else { return }
        hardwareMap = engine.hardwareMap
        do {
            try stores.hardwareMap.save(hardwareMap)
        } catch {
            notice = ConsoleNotice(level: .error, text: "硬件映射保存失败：\(error.localizedDescription)")
        }
    }

    private func persistConfiguration() {
        do {
            try stores.configuration.save(engine.configuration)
        } catch {
            notice = ConsoleNotice(level: .error, text: "功能配置保存失败：\(error.localizedDescription)")
        }
    }

    /// Publishes agent slots and writes a changed state to the slot's LEDs.
    func applyAgentSlots(_ newSlots: [AgentSlot], changed slotID: AgentSlotID) {
        let previous = slot(slotID)?.state
        slots = newSlots
        guard let state = slot(slotID)?.state, state != previous else { return }
        perform(engine.setAgentFeedback(slotID, value: state.feedbackValue))
    }

    func report(_ error: Error) {
        notice = ConsoleNotice(level: .error, text: error.localizedDescription)
    }
}
