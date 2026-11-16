import BCRFoundation
import Foundation
import struct SurfacePluginContracts.ActionReference
import struct SurfacePluginContracts.IndicatorID

public enum MIDILearnFormat: String, CaseIterable, Sendable { case voice, nrpn14 }

public enum SurfaceWriteOrigin: String, Equatable, Sendable {
    case software, agent, external
}

public struct MonitorEvent: Identifiable, Equatable, Sendable {
    public let id: Int
    public let time: Date
    public let monotonicTime: Double
    public let direction: MIDIObservationDirection
    public let source: DeviceSource
    public let message: MIDIVoiceMessage
    public let control: BCRControlID?
    public let ignored: Bool
    public let origin: SurfaceWriteOrigin
    public let delivery: FeedbackDelivery?
}

/// Semantic notifications let the app own wording, selection and follow-touch policy.
public enum SurfaceSessionEvent: Equatable, Sendable {
    case sourceChanged(DeviceSource)
    case pageChanged
    case connected(MIDIConnectionSnapshot)
    case touched(BCRControlID)
    case buttonActivity(BCRControlID, pressed: Bool?)
    /// A control was operated on the device itself (not an echo of feedback), with the raw value it sent.
    case deviceInput(BCRControlID, rawValue: UInt16, pressed: Bool?)
    case learningInterruptedByConfiguration(BCRControlID)
    case learned(BCRControlID, MIDIControlID, next: BCRControlID?)
    case learnRejected(BCRControlID, HardwareBindingError)
    case failed(Operation, String)

    public enum Operation: Equatable, Sendable {
        case feedback, hardwareMapPersistence, configurationPersistence
        /// A trusted hardware observation the optional contract journal refused before commit.
        case hardwareInput
    }
}

/// Testable orchestration shared by physical and mock devices. All feedback goes through
/// engine effects, including Agent LEDs. Persistence and Agent execution are injected.
@MainActor
public final class SurfaceSession {
    public private(set) var source: DeviceSource = .mock
    public private(set) var engine: SurfaceEngine
    /// Whole-configuration replacement resets live values even when definitions compare equal.
    public private(set) var configurationRevision: UInt64 = 0
    /// Increments on every change that can alter a control's mapping or input interpretation:
    /// configuration, parameter definitions, assignments, page, source, hardware/Mock map, learning
    /// and Mock wire encoding. Optional simulation adapters compare it instead of encoding the
    /// whole configuration; it does not change on ordinary input, parameter or feedback writes.
    public private(set) var mappingContextRevision: UInt64 = 0
    private func noteMappingContextChanged() { mappingContextRevision &+= 1 }
    public var mock: MockBCR2000 { mockDevice.model }
    public private(set) var connection: MIDIConnectionSnapshot
    public private(set) var events: [MonitorEvent] = []
    public private(set) var droppedFeedbackCount = 0
    public let inputEvents = ProviderEventJournal(source: .mock)
    public private(set) var diagnosticReadbackActive = false
    private var diagnosticToken: String?
    /// App-owned safety configuration; MCP cannot change which parameter is the enable gate.
    public private(set) var outputEnableParameter: ParameterID?
    public func setOutputEnableParameter(_ id: ParameterID) { outputEnableParameter = id }
    public func isMCPProtectedParameter(_ id: ParameterID) -> Bool {
        engine.configuration.parameter(id)?.externallyProtected == true || id == outputEnableParameter
    }

    public private(set) var motionSafety: MotionSafetySnapshot?
    public private(set) var lastConfigurationPersistenceError: String?

    private var parameterRevision: UInt64 = 0
    private var publishedValues: [ParameterID: Double] = [:]
    private var publishedConfigurationRevision: UInt64 = 0
    private var parameterObservers: [UUID: @MainActor (ParameterChangeBatch) -> Void] = [:]

    public func observeParameters(_ observer: @escaping @MainActor (ParameterChangeBatch) -> Void) -> UUID {
        let id = UUID()
        parameterObservers[id] = observer
        return id
    }

    var parameterObserverCount: Int { parameterObservers.count }
    public func removeParameterObserver(_ id: UUID) { parameterObservers[id] = nil }
    public func parameterSnapshot() -> ParameterChangeBatch {
        ParameterChangeBatch(revision: parameterRevision,
                             values: Dictionary(uniqueKeysWithValues: engine.parameterValues.map { (
                                 $0.key.rawValue,
                                 $0.value
                             ) }),
                             removed: [], reset: true)
    }

    private func publishChange() {
        let values = engine.parameterValues
        let reset = publishedConfigurationRevision != configurationRevision
        let changed = values.filter { publishedValues[$0.key] != $0.value }
        let removed = publishedValues.keys.filter { values[$0] == nil }.map(\.rawValue).sorted()
        publishedValues = values
        publishedConfigurationRevision = configurationRevision
        if reset || !changed.isEmpty || !removed.isEmpty {
            parameterRevision &+= 1
            let batch = ParameterChangeBatch(revision: parameterRevision,
                                             values: Dictionary(uniqueKeysWithValues: (reset ? values : changed).map { (
                                                 $0.key.rawValue,
                                                 $0.value
                                             ) }),
                                             removed: removed, reset: reset)
            for observer in Array(parameterObservers.values) { observer(batch) }
        }
        onChange?()
    }

    private var monitorObservers: [UUID: @MainActor (MonitorEvent, Bool) -> Void] = [:]
    public func observeMonitor(_ observer: @escaping @MainActor (MonitorEvent, Bool) -> Void) -> UUID {
        let id = UUID(); monitorObservers[id] = observer; return id
    }

    public func removeMonitorObserver(_ id: UUID) { monitorObservers[id] = nil }

    private var captureObservers: [UUID: @MainActor (MonitorCaptureRecord) -> Void] = [:]
    public func observeCapture(_ observer: @escaping @MainActor (MonitorCaptureRecord) -> Void) -> UUID {
        let id = UUID(); captureObservers[id] = observer; return id
    }

    public func removeCaptureObserver(_ id: UUID) { captureObservers[id] = nil }
    private func publishCapture(_ record: MonitorCaptureRecord) {
        for observer in Array(captureObservers.values) { observer(record) }
    }

    private func observeSysEx(_ data: Data) {
        guard !captureObservers.isEmpty else { return }
        publishCapture(.sysEx(data, at: now(), monotonic: historyTime.now()))
    }

    public func captureHeader(sessionID: String, applicationVersion: String) throws -> MonitorCaptureRecord {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let map = source == .mock ? mock.preset : learnedHardwareMap
        let connection = source == .mock ? mockDevice.connection : self.connection
        return try .start(sessionID: sessionID, applicationVersion: applicationVersion, source: source,
                          connection: connection, mappingFingerprint: ContentDigest.sha256(encoder.encode(map)),
                          configuration: engine.configuration, hardwareMap: map,
                          parameterValues: engine.parameterValues,
                          at: now(),
                          monotonic: historyTime.now())
    }

    public func captureEnd(eventCount: Int) -> MonitorCaptureRecord {
        .end(at: now(), monotonic: historyTime.now(), eventCount: eventCount)
    }

    public var onChange: (@MainActor () -> Void)?
    public var onEvent: (@MainActor (SurfaceSessionEvent) -> Void)?
    /// Legacy-only callback for callers without injected plugin bindings (workspace D8).
    public var onTriggerAgent: (@MainActor (AgentSlotID) -> Void)?
    public var onTriggerAction: (@MainActor (ActionReference) -> Void)?
    private var acceptedInputObservers: [UUID: @MainActor (BCRControlID, MIDIVoiceMessage, Double?, SurfaceWriteOrigin)
        -> Void] = [:]
    public func observeAcceptedInput(
        _ observer: @escaping @MainActor (BCRControlID, MIDIVoiceMessage, Double?, SurfaceWriteOrigin) -> Void
    ) -> UUID {
        let token = UUID(); acceptedInputObservers[token] = observer; return token
    }

    public func removeAcceptedInputObserver(_ token: UUID) { acceptedInputObservers[token] = nil }

    /// Optional trusted contract transaction hooks; never exposed through remote tools.
    /// Preflight runs before the candidate engine changes; commit runs before both values publish.
    public var hardwareInputPreflight: (@MainActor (BCRControlID, MIDIVoiceMessage) throws -> Void)?
    public var hardwareInputCommit: (@MainActor (BCRControlID, MIDIVoiceMessage, SurfaceEngine, Bool) throws -> Void)?

    private let hardwareDevice: any SurfaceDevice
    private let requiresHardwareConfirmation: Bool
    public let hardwareOutput: HardwareOutputPolicy
    /// Headless hardware-contract hosts never replay retained display state on lifecycle changes.
    private let hardwareLifecycleFeedback: Bool
    private let mockDevice: MockSurfaceDevice
    private let now: @MainActor () -> Date
    private let historyTime: HostTime
    private let saveHardwareMap: @MainActor (HardwareMap) throws -> Void
    private let saveConfiguration: @MainActor (SurfaceConfiguration) throws -> Void
    private var hardwareMap: HardwareMap
    private var nextEventID = 0
    public private(set) var learnFormat: MIDILearnFormat = .voice
    private var nrpnAssembler = NRPNAssembler()
    public private(set) var feedbackPolicy = FeedbackPolicy()
    private var scheduler: FeedbackScheduler?
    private let feedbackPlanner = FeedbackPlanner()
    public var pendingFeedbackCount: Int { scheduler?.count ?? 0 }
    private var feedbackObservers: [UUID: @MainActor (Int) -> Void] = [:]
    public func observeFeedbackQueue(_ observer: @escaping @MainActor (Int) -> Void) -> UUID {
        let token = UUID(); feedbackObservers[token] = observer; return token
    }

    public func removeFeedbackObserver(_ token: UUID) { feedbackObservers[token] = nil }
    private func notifyFeedbackQueue() {
        for observer in Array(feedbackObservers.values) { observer(pendingFeedbackCount) }
    }

    private func clearFeedbackQueue() { scheduler?.clear(); notifyFeedbackQueue() }
    private var writeOrigin: SurfaceWriteOrigin = .software
    public private(set) var valueHistory = ParameterValueHistory()
    public private(set) var highlightedGroup: String?
    private var valueTransactionDepth = 0
    private var restoringHistory = false
    public var canUndo: Bool { valueHistory.canUndo }
    public var canRedo: Bool { valueHistory.canRedo }

    /// Nesting keeps macros, group resets and authenticated batches in one value-only step.
    public func withParameterHistory<T>(key: String? = nil, _ operation: () throws -> T) rethrows -> T {
        let before = engine.parameterValues
        let revision = configurationRevision, previousSource = source
        let outermost = valueTransactionDepth == 0
        valueTransactionDepth += 1
        defer {
            valueTransactionDepth -= 1
            if outermost, !restoringHistory, revision == configurationRevision, previousSource == source {
                valueHistory.record(before: before, after: engine.parameterValues,
                                    key: key.map { "\(source.rawValue):\(writeOrigin.rawValue):\($0)" },
                                    at: historyTime.now())
                onChange?()
            }
        }
        return try operation()
    }

    public func setParameterColor(_ color: ParameterColor?, for id: ParameterID) throws {
        try engine.setParameterColor(color, for: id)
        persistConfiguration(); publishChange()
    }

    public func highlightGroup(_ group: String?) throws {
        guard group == nil || engine.configuration.parameterGroups.contains(group!)
        else { throw MotionSafetyError(L10n.text("未知参数组")) }
        highlightedGroup = group
        publishChange()
    }

    public func captureScene(id: String, name: String, overwrite: Bool = false) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var scenes = engine.configuration.scenes ?? []
        let existing = scenes.firstIndex { $0.id == id || $0.name == name }
        if existing != nil, !overwrite { throw ParameterSceneError.overwriteRequiresConfirmation }
        let scene = ParameterScene(id: existing.map { scenes[$0].id } ?? id, name: name,
                                   values: Dictionary(uniqueKeysWithValues: engine.parameterValues.map {
                                       ($0.key.rawValue, $0.value)
                                   }))
        if let existing { scenes[existing] = scene } else { scenes.append(scene) }
        try engine.setScenes(scenes)
        persistConfiguration(); publishChange()
    }

    public func renameScene(_ id: String, to name: String) throws {
        var scenes = engine.configuration.scenes ?? []
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { throw ParameterSceneError.unknownScene }
        scenes[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try engine.setScenes(scenes)
        persistConfiguration(); publishChange()
    }

    public func deleteScene(_ id: String) throws {
        guard let scenes = engine.configuration.scenes, scenes.contains(where: { $0.id == id })
        else { throw ParameterSceneError.unknownScene }
        try engine.setScenes(scenes.filter { $0.id != id })
        persistConfiguration(); publishChange()
    }

    @discardableResult
    public func recallScene(_ id: String) throws -> SceneRecallResult {
        guard let scene = engine.configuration.scenes?.first(where: { $0.id == id })
        else { throw ParameterSceneError.unknownScene }
        let missing = scene.values.keys.filter { engine.configuration.parameter(ParameterID($0)) == nil }.sorted()
        let changes = scene.values.filter { key, value in
            engine.configuration.parameter(ParameterID(key)) != nil && engine.value(of: ParameterID(key)) != value
        }
        for key in changes.keys {
            let id = ParameterID(key)
            guard engine.configuration.parameter(id)?.agentWritable == true, !isMCPProtectedParameter(id)
            else { throw ParameterSceneError.protectedParameter(id) }
        }
        withParameterHistory {
            for key in changes.keys.sorted() { setParameter(ParameterID(key), to: changes[key]!) }
        }
        return SceneRecallResult(missingParameters: missing)
    }

    public func endParameterHistoryGroup() { valueHistory.endGroup() }
    public func undo() throws { try restoreParameterHistory(redo: false) }
    public func redo() throws { try restoreParameterHistory(redo: true) }

    private func restoreParameterHistory(redo: Bool) throws {
        guard let entry = redo ? valueHistory.redoEntry : valueHistory.undoEntry else { return }
        let target = redo ? entry.after : entry.before
        let existing = target.filter { engine.configuration.parameter($0.key) != nil }
        // Validate the whole batch before any write; permissions may have changed since capture.
        for id in existing.keys {
            guard engine.configuration.parameter(id)?.agentWritable == true, !isMCPProtectedParameter(id)
            else { throw ParameterHistoryError(parameter: id) }
        }
        let before = engine.parameterValues
        restoringHistory = true
        defer { restoringHistory = false }
        withParameterHistory {
            for id in existing.keys.sorted(by: { $0.rawValue < $1.rawValue }) { setParameter(id, to: existing[id]!) }
        }
        if redo { valueHistory.didRedo(actualBefore: before, actualAfter: engine.parameterValues) }
        else { valueHistory.didUndo(actualBefore: before, actualAfter: engine.parameterValues) }
        publishChange()
    }

    public init(
        hardwareDevice: any SurfaceDevice,
        mockDevice: MockSurfaceDevice = MockSurfaceDevice(),
        hardwareMap: HardwareMap = HardwareMap(),
        configuration: SurfaceConfiguration = .neutral(),
        pluginBindings: SurfacePluginBindings = .init(),
        requiresHardwareConfirmation: Bool = false,
        hardwareOutput: HardwareOutputPolicy = .write,
        hardwareLifecycleFeedback: Bool = true,
        now: @escaping @MainActor () -> Date = { .now },
        historyTime: HostTime = .live,
        saveHardwareMap: @escaping @MainActor (HardwareMap) throws -> Void,
        saveConfiguration: @escaping @MainActor (SurfaceConfiguration) throws -> Void
    ) {
        self.hardwareDevice = hardwareDevice
        self.requiresHardwareConfirmation = requiresHardwareConfirmation
        self.hardwareOutput = hardwareOutput
        self.hardwareLifecycleFeedback = hardwareLifecycleFeedback
        self.mockDevice = mockDevice
        self.hardwareMap = hardwareMap
        self.now = now
        self.historyTime = historyTime
        self.saveHardwareMap = saveHardwareMap
        self.saveConfiguration = saveConfiguration
        connection = hardwareDevice.connection
        engine = SurfaceEngine(hardwareMap: mockDevice.model.preset, configuration: configuration,
                               pluginBindings: pluginBindings)
        publishedValues = engine.parameterValues
        mockDevice.configureModes(configuration)
        engine.echoWindow = 0 // Mock never echoes feedback; real-device suppression is restored on source switch.
        (hardwareDevice as? any SurfaceSysExObserving)?.onSysExObservation = { [weak self] in self?.observeSysEx($0) }
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

    public func configureFeedback(_ policy: FeedbackPolicy) throws {
        let updated = try FeedbackScheduler(policy: policy)
        engine.recordFeedbackWhenGenerated = !policy.enabled && source == .mock
        feedbackPolicy = policy
        scheduler = updated
        notifyFeedbackQueue()
        if source == .hardware { performLifecycleFeedback(engine.fullFeedback(at: now())) }
        publishChange()
    }

    public func flushFeedback() {
        guard source == .hardware, feedbackPolicy.enabled else { return }
        let batch = scheduler?.drain(at: now()) ?? []
        for (index, value) in batch.enumerated() {
            let result = withWriteOrigin(value.origin) { transmitNow(value.message) }
            if result == .failed {
                for remaining in batch[index...] { scheduler?.enqueue(remaining.message, origin: remaining.origin) }
                break
            }
        }
        notifyFeedbackQueue()
        if !batch.isEmpty { publishChange() }
    }

    public func synchronize() {
        performLifecycleFeedback(engine.fullFeedback(at: now()))
        publishChange()
    }

    /// GUI startup adopts a complete hardware observation before enabling the hardware source.
    public func adoptHardwareSnapshot(_ messages: [MIDIVoiceMessage]) throws {
        guard source == .mock, connection.isConnected, engine.learnTarget == nil,
              motionSafety == nil || motionSafety?.status == .disconnected else { throw HardwareSnapshotError.invalid }
        var candidate = engine
        _ = candidate.clearDisplayFeedback(at: now())
        candidate.replaceHardwareMap(hardwareMap)
        try candidate.adoptHardwareSnapshot(messages)
        clearFeedbackQueue()
        engine = candidate
        source = .hardware
        valueHistory.clear()
        engine.recordFeedbackWhenGenerated = false
        engine.echoWindow = 0.18
        diagnosticReadbackActive = false; diagnosticToken = nil
        nrpnAssembler.reset()
        invalidateInputEpoch("startup_snapshot")
        noteMappingContextChanged()
        droppedFeedbackCount = 0
        onEvent?(.sourceChanged(.hardware))
        // Encoder values came from the device; button LEDs still show the software state, because
        // after a restart the device keeps lights for Agent states the software no longer has.
        performLifecycleFeedback(engine.buttonFeedback(at: now()))
        publishChange()
    }

    public func selectSource(_ newSource: DeviceSource) {
        guard newSource != source else { return }
        clearFeedbackQueue()
        _ = engine.clearDisplayFeedback(at: now())
        source = newSource
        valueHistory.clear()
        engine.recordFeedbackWhenGenerated = !feedbackPolicy.enabled && newSource == .mock
        diagnosticReadbackActive = false; diagnosticToken = nil
        invalidateInputEpoch("source_changed")
        noteMappingContextChanged()
        nrpnAssembler.reset()
        engine.echoWindow = newSource == .mock ? 0 : 0.18
        engine.replaceHardwareMap(newSource == .mock ? mock.preset : hardwareMap)
        droppedFeedbackCount = 0
        onEvent?(.sourceChanged(newSource))
        performLifecycleFeedback(engine.fullFeedback(at: now()))
        publishChange()
    }

    public func updatePrograms(_ candidate: SurfaceConfiguration) throws {
        perform(try engine.updatePrograms(candidate, at: now()))
        publishChange()
    }

    public func selectPage(_ id: String?) throws {
        perform(try engine.selectPage(id, at: now()))
        publishChange()
    }

    public func selectGroup(_ group: Int) {
        mockDevice.selectGroup(group)
        publishChange()
    }

    public func turn(_ control: BCRControlID, by delta: Int) {
        withParameterHistory(key: "control:\(control)") {
            if source == .mock { mockDevice.turn(control, by: delta) }
            else { perform(engine.adjust(control, by: delta, at: now())) }
        }
        publishChange()
    }

    public func press(_ control: BCRControlID) {
        withParameterHistory {
            if source == .mock { mockDevice.press(control) }
            else { perform(engine.press(control, isDown: true, at: now())) }
        }
        publishChange()
    }

    public func release(_ control: BCRControlID) {
        withParameterHistory {
            if source == .mock { mockDevice.release(control) }
            else { perform(engine.press(control, isDown: false, at: now())) }
        }
        publishChange()
    }

    public func setParameter(_ id: ParameterID, to value: Double) {
        withParameterHistory(key: "parameter:\(id)") {
            perform(engine.setParameter(id, to: value, at: now()))
        }
        inputEvents.append(kind: "parameter.write", payload: .object([
            "parameter_id": .string(id.rawValue), "origin": .string(writeOrigin.rawValue),
            "mapped_value": engine.value(of: id).map(JSONValue.double) ?? .null
        ]))
        publishChange()
    }

    @discardableResult
    public func runMacro(_ id: String) -> MacroExecution {
        let execution = withParameterHistory {
            let result = engine.runMacro(id, at: now())
            perform(result.effects)
            return result
        }
        publishChange()
        return execution
    }

    public func resetGroup(_ group: String) {
        withParameterHistory { perform(engine.resetGroup(group, at: now())) }
        publishChange()
    }

    public func bindIndicator(_ indicator: IndicatorID, to target: ControlTarget) {
        engine.bindIndicator(indicator, to: target)
    }

    public func setIndicatorFeedback(_ id: IndicatorID, value: UInt8) {
        perform(engine.setIndicatorFeedback(id, value: value, at: now()))
        publishChange()
    }

    @discardableResult
    public func createParameter(assigningTo control: BCRControlID? = nil) throws -> ParameterID {
        let id = engine.configuration.makeParameterID()
        let number = id.rawValue.split(separator: ".").last.map(String.init) ?? ""
        let definition = control.map { !$0.isContinuous } ?? false
            ? ParameterDefinition(
                id: id,
                name: L10n.text("开关 \(number)"),
                group: L10n.text("自定义"),
                minimum: 0,
                maximum: 1,
                kind: .toggle
            )
            : ParameterDefinition(
                id: id,
                name: L10n.text("参数 \(number)"),
                group: L10n.text("自定义"),
                minimum: 0,
                maximum: 127
            )
        try addParameter(definition, assigningTo: control)
        return id
    }

    public func addParameter(_ definition: ParameterDefinition, assigningTo control: BCRControlID? = nil) throws {
        try engine.addParameter(definition)
        noteMappingContextChanged()
        if let control {
            perform(try engine.assign(
                ControlAssignment(control: control, target: .parameter(definition.id)),
                at: now()
            ))
        }
        persistConfiguration()
        publishChange()
    }

    public func updateParameter(_ definition: ParameterDefinition) throws {
        perform(try engine.updateParameter(definition, at: now()))
        noteMappingContextChanged()
        persistConfiguration()
        publishChange()
    }

    public func removeParameter(_ id: ParameterID) {
        engine.removeParameter(id)
        noteMappingContextChanged()
        persistConfiguration()
        publishChange()
    }

    public func replaceConfiguration(_ configuration: SurfaceConfiguration, persist: Bool = true) throws {
        let configuration = try configuration.migrated()
        let learning = engine.learnTarget
        let clearedFeedback = engine.replaceConfiguration(configuration, at: now())
        clearFeedbackQueue()
        configurationRevision &+= 1
        highlightedGroup = nil
        valueHistory.clear()
        noteMappingContextChanged()
        mockDevice.configureModes(configuration)
        nrpnAssembler.reset()
        if let learning { onEvent?(.learningInterruptedByConfiguration(learning)) }
        performLifecycleFeedback(clearedFeedback + engine.fullFeedback(at: now()))
        if persist { persistConfiguration() }
        else { lastConfigurationPersistenceError = nil }
        publishChange()
    }

    public func setActualFeedback(_ values: [ParameterID: Double]) throws {
        let effects = try engine.setActualFeedback(values, at: now())
        withWriteOrigin(.external) { perform(effects) }
        if !effects.isEmpty { onChange?() }
    }

    /// Side-effect-free check of every condition `setSimulationDisplayFeedback` can reject.
    public func validateSimulationDisplayFeedback(_ control: BCRControlID, rawValue: UInt16) throws {
        guard source == .mock, let midi = engine.hardwareMap.midi(for: control),
              rawValue <= (midi.kind == .nrpn ? 16383 : 127)
        else { throw ProviderDomainError("unsupported", "Simulation display feedback requires a valid Mock control") }
    }

    /// Explicit simulation display route. It never writes a parameter or injects input.
    public func setSimulationDisplayFeedback(_ control: BCRControlID, rawValue: UInt16) throws {
        try validateSimulationDisplayFeedback(control, rawValue: rawValue)
        let effects = try engine.setDisplayFeedback(control, rawValue: rawValue, at: now())
        withWriteOrigin(.external) { perform(effects) }
        publishChange()
    }

    /// Explicit display-only request through the existing effect/transmit exit. No input or parameter write.
    public func setHardwareDisplayFeedback(_ control: BCRControlID, rawValue: UInt16) throws {
        guard source == .hardware, hardwareOutput == .write, connection.isConnected,
              !diagnosticReadbackActive, let midi = engine.hardwareMap.midi(for: control),
              !engine.hardwareMap.isVisualizationOnly(control), midi.kind != .nrpn, rawValue <= 127
        else { throw ProviderDomainError("permission_denied", "Hardware display output is not permitted") }
        let previous = engine
        var candidate = engine
        let effects = try candidate.setDisplayFeedback(control, rawValue: rawValue, at: now())
        guard !effects.isEmpty else { throw ProviderDomainError("unsupported_feedback", "No display route") }
        let mark = nextEventID
        engine = candidate
        let plan = FeedbackBatchPlan(effects: effects, origin: .external, timing: .synchronous)
        try feedbackPlanner.withBatch(plan) {
            withWriteOrigin(plan.origin) { perform(plan.effects) }
            let outputs = events.filter { $0.id > mark && $0.direction == .output }
            guard !outputs.isEmpty, outputs.allSatisfy({ $0.delivery == .sent }) else {
                // Keep the engine on what the device shows: roll back only when nothing reached it.
                if !outputs.contains(where: { $0.delivery == .sent }) { engine = previous }
                publishChange()
                throw ProviderDomainError("delivery_failed", "Display transport did not accept output")
            }
            publishChange()
        }
    }

    public func clearSimulationDisplayFeedback() throws {
        guard source == .mock
        else { throw ProviderDomainError("unsupported", "Simulation feedback requires Mock source") }
        perform(engine.clearDisplayFeedback(at: now()))
        publishChange()
    }

    /// A fresh simulator context starts with its own all-off raw controls, without operator events.
    public func resetSimulationInputs() throws {
        guard source == .mock else { throw ProviderDomainError("unsupported", "Simulation reset requires Mock source") }
        let configuration = try engine.configuration.migrated() // Validate before the Mock reset.
        mockDevice.resetInputState()
        try replaceConfiguration(configuration, persist: false)
    }

    /// Side-effect-free check of every condition `resetSimulationContext` can reject.
    public func validateSimulationReset() throws {
        guard source == .mock else { throw ProviderDomainError("unsupported", "Simulation reset requires Mock source") }
        _ = try engine.configuration.migrated()
    }

    /// Clears the simulation display overlay and Mock input state as one operation. Every
    /// fallible check runs before the first change.
    public func resetSimulationContext() throws {
        try validateSimulationReset()
        perform(engine.clearDisplayFeedback(at: now()))
        try resetSimulationInputs()
    }

    /// Simulation-only absolute input: moves a Mock absolute encoder to `rawValue` regardless of
    /// the position currently shown by display feedback. Hardware sources are never touched.
    public func simulateAbsoluteInput(_ control: BCRControlID, rawValue: UInt16) {
        guard source == .mock else { return }
        engine.resetAbsoluteInputTracking(for: control)
        mockDevice.move(control, to: rawValue)
        publishChange()
    }

    public func setLEDFeedbackSource(_ source: LEDFeedbackSource) {
        perform(engine.setLEDFeedbackSource(source, at: now()))
        publishChange()
    }

    public func setMotionSafety(_ snapshot: MotionSafetySnapshot) {
        motionSafety = snapshot // The output controller publishes its own UI; MCP reads this value directly.
    }

    public func retryConfigurationPersistence() {
        persistConfiguration()
        publishChange()
    }

    public func setAssignment(_ assignment: ControlAssignment?, for control: BCRControlID) throws {
        if let assignment { perform(try engine.assign(assignment, at: now())) }
        else { perform(engine.clearAssignment(for: control, at: now())) }
        noteMappingContextChanged()
        mockDevice.configureModes(engine.configuration)
        persistConfiguration()
        publishChange()
    }

    public func applyBulkAssignment(_ plan: BulkAssignmentPlan) throws {
        perform(try engine.apply(plan, at: now()))
        noteMappingContextChanged()
        mockDevice.configureModes(engine.configuration)
        persistConfiguration()
        publishChange()
    }

    @discardableResult
    public func beginLearning(at control: BCRControlID, format: MIDILearnFormat = .voice) -> Bool {
        guard source == .hardware else { return false }
        invalidateInputEpoch("learning_started")
        noteMappingContextChanged()
        learnFormat = format
        nrpnAssembler.reset()
        engine.beginLearning(control)
        publishChange()
        return true
    }

    public func stopLearning() {
        if engine.learnTarget != nil { invalidateInputEpoch("learning_stopped"); noteMappingContextChanged() }
        engine.stopLearning()
        nrpnAssembler.reset()
        publishChange()
    }

    public func unbind(_ control: BCRControlID) {
        guard source == .hardware else { return }
        engine.unbind(control)
        noteMappingContextChanged()
        persistHardwareMap()
        publishChange()
    }

    /// The persisted physical map, independent of which source is active.
    public var learnedHardwareMap: HardwareMap { hardwareMap }

    /// Installs a map the device has just been aligned to (identities, ring and press modes).
    public func installHardwareMap(_ map: HardwareMap) throws {
        try map.validate()
        invalidateInputEpoch("mapping_changed")
        noteMappingContextChanged()
        if engine.learnTarget != nil { engine.stopLearning() }
        hardwareMap = map
        if source == .hardware { engine.replaceHardwareMap(map) }
        do { try saveHardwareMap(map) }
        catch { onEvent?(.failed(.hardwareMapPersistence, error.localizedDescription)) }
        publishChange()
    }

    public func resetHardwareMap() {
        guard source == .hardware else { return }
        engine.resetHardwareMap()
        noteMappingContextChanged()
        persistHardwareMap()
        publishChange()
    }

    public func setMockNRPN(_ enabled: Bool, for control: BCRControlID) throws {
        guard source == .mock else { return }
        invalidateInputEpoch("mock_encoding_changed")
        noteMappingContextChanged()
        try mockDevice.setNRPN(enabled, for: control)
        engine.replaceHardwareMap(mock.preset)
        nrpnAssembler.reset()
        performLifecycleFeedback(engine.fullFeedback(at: now()))
        publishChange()
    }

    public func clearMonitor() {
        events.removeAll()
        publishChange()
    }

    private func receive(_ messages: [MIDIVoiceMessage], from inputSource: DeviceSource) {
        for rawMessage in messages {
            let inputGeneration = inputEvents.generation
            let ignored = inputSource != source || diagnosticReadbackActive
            let map = inputSource == .hardware ? hardwareMap : mock.preset
            let rawControl = map.control(for: rawMessage.controlID)
            log(.input, rawMessage, source: inputSource, control: rawControl, ignored: ignored)
            guard !ignored, inputGeneration == inputEvents.generation else { continue }
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
            if engine.learnTarget == nil, let control, !control.isContinuous {
                let pressed = map.pressMode(for: control) == .momentary ? message.isPositiveActivation : nil
                // A release must never be lost to echo suppression, or a held button stays drawn as pressed.
                if pressed == false || !engine.isFeedbackEcho(message, at: now()) {
                    onEvent?(.buttonActivity(control, pressed: pressed))
                }
            }
            if engine.learnTarget == nil, let control { onEvent?(.touched(control)) }
            if let control, !engine.isFeedbackEcho(message, at: now()) {
                let pressed = control.isContinuous || map.pressMode(for: control) != .momentary
                    ? nil : message.isPositiveActivation
                onEvent?(.deviceInput(control, rawValue: message.dataValue, pressed: pressed))
            }
            guard inputGeneration == inputEvents.generation else { continue }
            let historyBefore = engine.parameterValues
            let historyRevision = configurationRevision
            let recordInputHistory = valueTransactionDepth == 0
            defer {
                if recordInputHistory, historyRevision == configurationRevision {
                    valueHistory.record(before: historyBefore, after: engine.parameterValues,
                                        key: control
                                            .flatMap {
                                                $0
                                                    .isContinuous ?
                                                    "\(writeOrigin.rawValue):input:\(inputSource.rawValue):\($0)" :
                                                    nil
                                            },
                                        at: historyTime.now())
                }
            }
            let previousCount = control.map { engine.state(of: $0).eventCount }
            let trusted = inputSource == .hardware && source == .hardware && !engine.isFeedbackEcho(message, at: now())
            let effects: [SurfaceEffect]
            if trusted, let control, hardwareInputPreflight != nil || hardwareInputCommit != nil {
                // The contract journal and the engine commit together: a rejected observation
                // changes neither (fail closed), and the failure stays visible.
                var candidate = engine
                do {
                    try hardwareInputPreflight?(control, message)
                    effects = candidate.handleInput(message, at: now())
                    try hardwareInputCommit?(control, message, candidate,
                                             previousCount != candidate.state(of: control).eventCount)
                } catch {
                    onEvent?(.failed(.hardwareInput, "Trusted hardware input rejected before commit: \(error)"))
                    continue
                }
                engine = candidate
            } else {
                effects = engine.handleInput(message, at: now())
            }
            if let control, previousCount != engine.state(of: control).eventCount {
                scheduler?.cancel(message.controlID)
                notifyFeedbackQueue()
            }
            perform(effects)
            if let control, inputGeneration == inputEvents.generation,
               previousCount != engine.state(of: control).eventCount
            {
                let parameter = engine.configuration.assignment(for: control)?.target.parameterID
                for observer in Array(acceptedInputObservers.values) {
                    observer(control, message, parameter.flatMap { engine.value(of: $0) }, writeOrigin)
                }
                inputEvents.append(kind: "control.input", payload: .object([
                    "origin": .string(writeOrigin == .agent ? "agent" :
                        (writeOrigin == .external ? "external" : (inputSource == .hardware ? "hardware" : "software"))),
                    "writer_origin": .string(writeOrigin.rawValue), "accepted": .bool(true),
                    "control": try! .encoded(control), "midi": try! .encoded(message.controlID),
                    "raw_value": .number(Int(message.dataValue)),
                    "mapped_value": parameter.flatMap { engine.value(of: $0) }.map(JSONValue.double) ?? .null
                ]), source: inputSource == .hardware ? .hardware : .mock)
            }
        }
        publishChange()
    }

    private func performLifecycleFeedback(_ effects: [SurfaceEffect]) {
        guard source != .hardware || hardwareLifecycleFeedback else {
            clearFeedbackQueue()
            return
        }
        perform(effects)
    }

    private func perform(_ effects: [SurfaceEffect], timing: FeedbackTiming? = nil) {
        for effect in effects {
            switch effect {
            case .pageChanged:
                invalidateInputEpoch("page_changed")
                noteMappingContextChanged()
                clearFeedbackQueue()
                nrpnAssembler.reset()
                mockDevice.configureModes(engine.configuration)
                onEvent?(.pageChanged)
            case .programsChanged:
                noteMappingContextChanged()
                clearFeedbackQueue()
                nrpnAssembler.reset()
                mockDevice.configureModes(engine.configuration)
                persistConfiguration()
                onEvent?(.pageChanged)
            case let .send(message): transmit(message, timing: timing)
            case let .triggerAgent(slot): onTriggerAgent?(slot)
            case let .triggerAction(action): onTriggerAction?(action)
            case let .learned(control, midi):
                noteMappingContextChanged()
                onEvent?(.learned(control, midi, next: engine.learnTarget))
                persistHardwareMap()
            case let .learnRejected(control, error): onEvent?(.learnRejected(control, error))
            case .unmappedInput: break // The raw input remains visible in the monitor.
            }
        }
    }

    private func transmit(_ message: MIDIVoiceMessage, timing: FeedbackTiming? = nil) {
        let plan = feedbackPlanner.message(message, origin: writeOrigin, requestedTiming: timing)
        if source == .hardware, hardwareOutput == .observe {
            log(.output, message, source: source, control: engine.hardwareMap.control(for: message.controlID),
                ignored: true, delivery: .suppressed)
            return
        }
        let canCoalesce = source == .hardware && feedbackPolicy.enabled && connection.connectedDestination != nil
        switch FeedbackScheduler.dispatch(plan, canCoalesce: canCoalesce) {
        case .enqueue:
            scheduler?.enqueue(plan.message, origin: plan.origin)
            notifyFeedbackQueue()
        case .send:
            _ = withWriteOrigin(plan.origin) { transmitNow(plan.message) }
        }
    }

    @discardableResult
    private func transmitNow(_ message: MIDIVoiceMessage) -> FeedbackDelivery {
        let device: any SurfaceDevice = source == .mock ? mockDevice : hardwareDevice
        let delivery: FeedbackDelivery
        if device.connection.connectedDestination == nil {
            droppedFeedbackCount += 1
            delivery = .disconnected
        } else {
            do {
                try device.send(message)
                engine.noteFeedbackSent(message, at: now())
                delivery = .sent
            } catch {
                droppedFeedbackCount += 1
                connection.lastError = error.localizedDescription
                scheduler?.noteFailure(at: now())
                onEvent?(.failed(.feedback, error.localizedDescription))
                delivery = .failed
            }
        }
        log(.output, message, source: source, control: engine.hardwareMap.control(for: message.controlID),
            ignored: false, delivery: delivery)
        return delivery
    }

    private func handleConnection(_ snapshot: MIDIConnectionSnapshot) {
        let wasConnected = connection.isConnected
        let routeChanged = connection.connectedSourceID != snapshot.connectedSourceID
            || connection.connectedDestinationID != snapshot.connectedDestinationID
            || connection.connectedSource != snapshot.connectedSource
            || connection.connectedDestination != snapshot.connectedDestination
        if snapshot.isConnected != wasConnected || routeChanged {
            nrpnAssembler.reset(); diagnosticReadbackActive = false; diagnosticToken = nil
            invalidateInputEpoch("connection_changed")
        }
        if routeChanged || !snapshot.isConnected { clearFeedbackQueue() }
        connection = snapshot
        if requiresHardwareConfirmation, source == .hardware, routeChanged || !snapshot.isConnected {
            selectSource(.mock)
        }
        if snapshot.isConnected, !wasConnected || routeChanged {
            onEvent?(.connected(snapshot))
            if source == .hardware {
                droppedFeedbackCount = 0
                performLifecycleFeedback(engine.fullFeedback(at: now()))
            }
        }
        publishChange()
    }

    private func log(
        _ direction: MIDIObservationDirection, _ message: MIDIVoiceMessage,
        source: DeviceSource, control: BCRControlID?, ignored: Bool, delivery: FeedbackDelivery? = nil
    ) {
        nextEventID += 1
        events.append(MonitorEvent(id: nextEventID, time: now(), monotonicTime: historyTime.now(), direction: direction,
                                   source: source, message: message, control: control, ignored: ignored,
                                   origin: writeOrigin, delivery: delivery))
        let echo = direction == .input && engine.isFeedbackEcho(message, at: now())
        if let event = events.last {
            for observer in Array(monitorObservers.values) { observer(event, echo) }
        }
        if !captureObservers.isEmpty, let event = events.last {
            // The record contains validated MIDI values only; no filesystem work runs on this path.
            publishCapture(MonitorCaptureRecord.event(
                event,
                feedbackEcho: echo,
                hardwareMode: self.source == .hardware
            ))
        }
        if events.count > 300 { events.removeFirst(events.count - 300) }
        let kind = direction == .input ? "control.raw" : "feedback.\(delivery?.rawValue ?? "generated")"
        let origin = diagnosticReadbackActive && direction == .input ? "readback" :
            (direction == .output || echo ? "feedback" : source.rawValue)
        inputEvents.append(kind: kind, payload: .object([
            "origin": .string(origin), "writer_origin": .string(writeOrigin.rawValue),
            "accepted": .bool(false), "ignored": .bool(ignored || echo || diagnosticReadbackActive),
            "control": control.map { try! .encoded($0) } ?? .null,
            "midi": try! .encoded(message.controlID), "raw_value": .number(Int(message.dataValue))
        ]), source: source == .hardware ? .hardware : .mock)
    }

    private func persistHardwareMap() {
        invalidateInputEpoch("mapping_changed")
        hardwareMap = engine.hardwareMap
        do { try saveHardwareMap(hardwareMap) }
        catch { onEvent?(.failed(.hardwareMapPersistence, error.localizedDescription)) }
    }

    private func persistConfiguration() {
        invalidateInputEpoch("configuration_changed")
        mockDevice.configureModes(engine.configuration)
        do {
            try saveConfiguration(engine.configuration)
            lastConfigurationPersistenceError = nil
        } catch {
            lastConfigurationPersistenceError = error.localizedDescription
            onEvent?(.failed(.configurationPersistence, error.localizedDescription))
        }
    }

    private func invalidateInputEpoch(_ reason: String) {
        inputEvents.reset(source: source == .hardware ? .hardware : .mock)
        inputEvents.append(
            kind: "context.changed",
            payload: .object(["reason": .string(reason), "diagnostic_readback": .bool(diagnosticReadbackActive)])
        )
    }

    public func beginDiagnosticReadback() throws -> String {
        try ProviderValidation.require(
            source == .hardware && connection.isConnected,
            "unsupported",
            "Diagnostic readback requires a connected hardware source"
        )
        try ProviderValidation.require(
            !diagnosticReadbackActive && engine.learnTarget == nil,
            "busy",
            "Stop learning or the existing diagnostic session first"
        )
        try ProviderValidation.require(
            motionSafety == nil || motionSafety?.status == .disconnected,
            "busy",
            "Stop external output before device diagnostics"
        )
        diagnosticReadbackActive = true; diagnosticToken = UUID().uuidString
        nrpnAssembler.reset(); invalidateInputEpoch("diagnostic_readback_started"); publishChange()
        return diagnosticToken!
    }

    public func endDiagnosticReadback(token: String) throws {
        try ProviderValidation.require(
            diagnosticReadbackActive && token == diagnosticToken,
            "invalid_control",
            "The diagnostic session is no longer owned by this caller"
        )
        abortDiagnosticReadback()
    }

    public func abortDiagnosticReadback() {
        diagnosticReadbackActive = false; diagnosticToken = nil; nrpnAssembler.reset()
        invalidateInputEpoch("diagnostic_readback_ended"); publishChange()
    }
}
