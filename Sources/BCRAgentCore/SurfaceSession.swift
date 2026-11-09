import Foundation

public enum MIDILearnFormat: String, CaseIterable, Sendable { case voice, nrpn14 }

public enum SurfaceWriteOrigin: String, Equatable, Sendable {
    case software, agent, external
}

public struct MonitorEvent: Identifiable, Equatable, Sendable {
    public let id: Int
    public let time: Date
    public let direction: MIDIObservationDirection
    public let source: DeviceSource
    public let message: MIDIVoiceMessage
    public let control: BCRControlID?
    public let ignored: Bool
    public let origin: SurfaceWriteOrigin
}

/// Semantic notifications let the app own wording, selection and follow-touch policy.
public enum SurfaceSessionEvent: Equatable, Sendable {
    case sourceChanged(DeviceSource)
    case connected(MIDIConnectionSnapshot)
    case touched(BCRControlID)
    case learningInterruptedByConfiguration(BCRControlID)
    case learned(BCRControlID, MIDIControlID, next: BCRControlID?)
    case learnRejected(BCRControlID, HardwareBindingError)
    case failed(Operation, String)

    public enum Operation: Equatable, Sendable {
        case feedback, hardwareMapPersistence, configurationPersistence
    }
}

/// Testable orchestration shared by physical and mock devices. All feedback goes through
/// engine effects, including Agent LEDs. Persistence and Agent execution are injected.
@MainActor
public final class SurfaceSession {
    public private(set) var source: DeviceSource = .mock
    public private(set) var engine: SurfaceEngine
    public var mock: MockBCR2000 { mockDevice.model }
    public private(set) var connection: MIDIConnectionSnapshot
    public private(set) var events: [MonitorEvent] = []
    public private(set) var droppedFeedbackCount = 0
    /// App-owned safety configuration; MCP cannot change which parameter is the enable gate.
    public private(set) var outputEnableParameter: ParameterID = "arm.enabled"
    public func setOutputEnableParameter(_ id: ParameterID) { outputEnableParameter = id }
    public func isMCPProtectedParameter(_ id: ParameterID) -> Bool {
        id == "arm.enabled" || id == outputEnableParameter
    }
    public private(set) var motionSafety: MotionSafetySnapshot?
    public private(set) var lastConfigurationPersistenceError: String?

    public var onChange: (@MainActor () -> Void)?
    public var onEvent: (@MainActor (SurfaceSessionEvent) -> Void)?
    public var onTriggerAgent: (@MainActor (AgentSlotID) -> Void)?

    private let hardwareDevice: any SurfaceDevice
    private let mockDevice: MockSurfaceDevice
    private let now: @MainActor () -> Date
    private let saveHardwareMap: @MainActor (HardwareMap) throws -> Void
    private let saveConfiguration: @MainActor (SurfaceConfiguration) throws -> Void
    private var hardwareMap: HardwareMap
    private var nextEventID = 0
    public private(set) var learnFormat: MIDILearnFormat = .voice
    private var nrpnAssembler = NRPNAssembler()
    private var writeOrigin: SurfaceWriteOrigin = .software

    public init(
        hardwareDevice: any SurfaceDevice,
        mockDevice: MockSurfaceDevice = MockSurfaceDevice(),
        hardwareMap: HardwareMap = HardwareMap(),
        configuration: SurfaceConfiguration = .robotArmDemo(),
        now: @escaping @MainActor () -> Date = { .now },
        saveHardwareMap: @escaping @MainActor (HardwareMap) throws -> Void,
        saveConfiguration: @escaping @MainActor (SurfaceConfiguration) throws -> Void
    ) {
        self.hardwareDevice = hardwareDevice
        self.mockDevice = mockDevice
        self.hardwareMap = hardwareMap
        self.now = now
        self.saveHardwareMap = saveHardwareMap
        self.saveConfiguration = saveConfiguration
        connection = hardwareDevice.connection
        engine = SurfaceEngine(hardwareMap: mockDevice.model.preset, configuration: configuration)
        mockDevice.configureModes(configuration)
        engine.echoWindow = 0 // Mock never echoes feedback; real-device suppression is restored on source switch.
        hardwareDevice.onMessages = { [weak self] in self?.receive($0, from: .hardware) }
        hardwareDevice.onConnection = { [weak self] in self?.handleConnection($0) }
        mockDevice.onMessages = { [weak self] in self?.receive($0, from: .mock) }
    }

    /// Source attribution is scoped to synchronous effect execution, including nested calls.
    public func withWriteOrigin<T>(_ origin: SurfaceWriteOrigin, _ operation: () throws -> T) rethrows -> T {
        let previous = writeOrigin
        writeOrigin = origin
        defer { writeOrigin = previous }
        return try operation()
    }

    public func synchronize() {
        perform(engine.fullFeedback(at: now()))
        onChange?()
    }

    public func selectSource(_ newSource: DeviceSource) {
        guard newSource != source else { return }
        source = newSource
        nrpnAssembler.reset()
        engine.echoWindow = newSource == .mock ? 0 : 0.18
        engine.replaceHardwareMap(newSource == .mock ? mock.preset : hardwareMap)
        droppedFeedbackCount = 0
        onEvent?(.sourceChanged(newSource))
        perform(engine.fullFeedback(at: now()))
        onChange?()
    }

    public func selectGroup(_ group: Int) {
        mockDevice.selectGroup(group)
        onChange?()
    }

    public func turn(_ control: BCRControlID, by delta: Int) {
        if source == .mock { mockDevice.turn(control, by: delta) }
        else { perform(engine.adjust(control, by: delta, at: now())) }
        onChange?()
    }

    public func press(_ control: BCRControlID) {
        if source == .mock { mockDevice.press(control) }
        else { perform(engine.press(control, isDown: true, at: now())) }
        onChange?()
    }

    public func release(_ control: BCRControlID) {
        if source == .mock { mockDevice.release(control) }
        else { perform(engine.press(control, isDown: false, at: now())) }
        onChange?()
    }

    public func setParameter(_ id: ParameterID, to value: Double) {
        perform(engine.setParameter(id, to: value, at: now()))
        onChange?()
    }

    public func resetGroup(_ group: String) {
        perform(engine.resetGroup(group, at: now()))
        onChange?()
    }

    public func setAgentFeedback(_ slot: AgentSlotID, value: UInt8) {
        perform(engine.setAgentFeedback(slot, value: value, at: now()))
        onChange?()
    }

    @discardableResult
    public func createParameter(assigningTo control: BCRControlID? = nil) throws -> ParameterID {
        let id = engine.configuration.makeParameterID()
        let number = id.rawValue.split(separator: ".").last.map(String.init) ?? ""
        let definition = control.map { !$0.isContinuous } ?? false
            ? ParameterDefinition(id: id, name: "开关 \(number)", group: "自定义", minimum: 0, maximum: 1, kind: .toggle)
            : ParameterDefinition(id: id, name: "参数 \(number)", group: "自定义", minimum: 0, maximum: 127)
        try addParameter(definition, assigningTo: control)
        return id
    }

    public func addParameter(_ definition: ParameterDefinition, assigningTo control: BCRControlID? = nil) throws {
        try engine.addParameter(definition)
        if let control {
            perform(try engine.assign(ControlAssignment(control: control, target: .parameter(definition.id)), at: now()))
        }
        persistConfiguration()
        onChange?()
    }

    public func updateParameter(_ definition: ParameterDefinition) throws {
        perform(try engine.updateParameter(definition, at: now()))
        persistConfiguration()
        onChange?()
    }

    public func removeParameter(_ id: ParameterID) {
        engine.removeParameter(id)
        persistConfiguration()
        onChange?()
    }

    public func replaceConfiguration(_ configuration: SurfaceConfiguration, persist: Bool = true) throws {
        let configuration = try configuration.migrated()
        let learning = engine.learnTarget
        engine.replaceConfiguration(configuration)
        mockDevice.configureModes(configuration)
        nrpnAssembler.reset()
        if let learning { onEvent?(.learningInterruptedByConfiguration(learning)) }
        perform(engine.fullFeedback(at: now()))
        if persist { persistConfiguration() }
        else { lastConfigurationPersistenceError = nil }
        onChange?()
    }

    public func setActualFeedback(_ values: [ParameterID: Double]) throws {
        let effects = try engine.setActualFeedback(values, at: now())
        withWriteOrigin(.external) { perform(effects) }
        if !effects.isEmpty { onChange?() }
    }

    public func setLEDFeedbackSource(_ source: LEDFeedbackSource) {
        perform(engine.setLEDFeedbackSource(source, at: now()))
        onChange?()
    }

    public func setMotionSafety(_ snapshot: MotionSafetySnapshot) {
        motionSafety = snapshot // The output controller publishes its own UI; MCP reads this value directly.
    }

    public func retryConfigurationPersistence() {
        persistConfiguration()
        onChange?()
    }

    public func setAssignment(_ assignment: ControlAssignment?, for control: BCRControlID) throws {
        if let assignment { perform(try engine.assign(assignment, at: now())) }
        else { engine.clearAssignment(for: control) }
        mockDevice.configureModes(engine.configuration)
        persistConfiguration()
        onChange?()
    }

    public func applyBulkAssignment(_ plan: BulkAssignmentPlan) throws {
        perform(try engine.apply(plan, at: now()))
        mockDevice.configureModes(engine.configuration)
        persistConfiguration()
        onChange?()
    }

    @discardableResult
    public func beginLearning(at control: BCRControlID, format: MIDILearnFormat = .voice) -> Bool {
        guard source == .hardware else { return false }
        learnFormat = format
        nrpnAssembler.reset()
        engine.beginLearning(control)
        onChange?()
        return true
    }

    public func stopLearning() {
        engine.stopLearning()
        nrpnAssembler.reset()
        onChange?()
    }

    public func unbind(_ control: BCRControlID) {
        guard source == .hardware else { return }
        engine.unbind(control)
        persistHardwareMap()
        onChange?()
    }

    public func resetHardwareMap() {
        guard source == .hardware else { return }
        engine.resetHardwareMap()
        persistHardwareMap()
        onChange?()
    }

    public func setMockNRPN(_ enabled: Bool, for control: BCRControlID) throws {
        guard source == .mock else { return }
        try mockDevice.setNRPN(enabled, for: control)
        engine.replaceHardwareMap(mock.preset)
        nrpnAssembler.reset()
        perform(engine.fullFeedback(at: now()))
        onChange?()
    }

    public func clearMonitor() {
        events.removeAll()
        onChange?()
    }

    private func receive(_ messages: [MIDIVoiceMessage], from inputSource: DeviceSource) {
        for rawMessage in messages {
            let ignored = inputSource != source
            let map = inputSource == .hardware ? hardwareMap : mock.preset
            let rawControl = map.control(for: rawMessage.controlID)
            log(.input, rawMessage, source: inputSource, control: rawControl, ignored: ignored)
            guard !ignored else { continue }
            var message = rawMessage
            if case let .controlChange(channel, number, _) = rawMessage {
                let learningNRPN = engine.learnTarget != nil && learnFormat == .nrpn14
                let mappedNRPN = map.entries.contains { $0.midi.kind == .nrpn && $0.midi.channel == channel }
                if learningNRPN || mappedNRPN {
                    let assembled = nrpnAssembler.consume(rawMessage, at: now())
                    if [6, 38, 98, 99, 100, 101, 121].contains(number) {
                        guard let assembled else { continue }
                        message = assembled
                    } else if learningNRPN { continue }
                }
            }
            if engine.learnTarget != nil {
                let isNRPN = message.controlID.kind == .nrpn
                if (learnFormat == .nrpn14) != isNRPN { continue }
            }
            let control = map.control(for: message.controlID)
            if engine.learnTarget == nil, let control { onEvent?(.touched(control)) }
            perform(engine.handleInput(message, at: now()))
        }
        onChange?()
    }

    private func perform(_ effects: [SurfaceEffect]) {
        for effect in effects {
            switch effect {
            case let .send(message): transmit(message)
            case let .triggerAgent(slot): onTriggerAgent?(slot)
            case let .learned(control, midi):
                onEvent?(.learned(control, midi, next: engine.learnTarget))
                persistHardwareMap()
            case let .learnRejected(control, error): onEvent?(.learnRejected(control, error))
            case .unmappedInput: break // The raw input remains visible in the monitor.
            }
        }
    }

    private func transmit(_ message: MIDIVoiceMessage) {
        log(.output, message, source: source, control: engine.hardwareMap.control(for: message.controlID), ignored: false)
        let device: any SurfaceDevice = source == .mock ? mockDevice : hardwareDevice
        guard device.connection.connectedDestination != nil else {
            droppedFeedbackCount += 1
            return
        }
        do { try device.send(message) }
        catch {
            droppedFeedbackCount += 1
            connection.lastError = error.localizedDescription
            onEvent?(.failed(.feedback, error.localizedDescription))
        }
    }

    private func handleConnection(_ snapshot: MIDIConnectionSnapshot) {
        let wasConnected = connection.isConnected
        let routeChanged = connection.connectedSourceID != snapshot.connectedSourceID
            || connection.connectedDestinationID != snapshot.connectedDestinationID
            || connection.connectedSource != snapshot.connectedSource
            || connection.connectedDestination != snapshot.connectedDestination
        if snapshot.isConnected != wasConnected || routeChanged { nrpnAssembler.reset() }
        connection = snapshot
        if snapshot.isConnected, !wasConnected || routeChanged {
            onEvent?(.connected(snapshot))
            if source == .hardware {
                droppedFeedbackCount = 0
                perform(engine.fullFeedback(at: now()))
            }
        }
        onChange?()
    }

    private func log(
        _ direction: MIDIObservationDirection, _ message: MIDIVoiceMessage,
        source: DeviceSource, control: BCRControlID?, ignored: Bool
    ) {
        nextEventID += 1
        events.append(MonitorEvent(id: nextEventID, time: now(), direction: direction,
                                   source: source, message: message, control: control, ignored: ignored, origin: writeOrigin))
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }

    private func persistHardwareMap() {
        hardwareMap = engine.hardwareMap
        do { try saveHardwareMap(hardwareMap) }
        catch { onEvent?(.failed(.hardwareMapPersistence, error.localizedDescription)) }
    }

    private func persistConfiguration() {
        mockDevice.configureModes(engine.configuration)
        do {
            try saveConfiguration(engine.configuration)
            lastConfigurationPersistenceError = nil
        } catch {
            lastConfigurationPersistenceError = error.localizedDescription
            onEvent?(.failed(.configurationPersistence, error.localizedDescription))
        }
    }
}
