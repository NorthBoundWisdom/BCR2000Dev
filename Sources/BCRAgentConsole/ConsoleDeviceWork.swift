import BCRFoundation
import BCRCodexAdapter
import BCRSurfaceDomain
import BCRExamples
import BCRConfigurationAdapter
import BCRMCPAdapter
import BCRHTTPTransport
import BCRCoreMIDIDriver
import BCRPersistenceAdapter
import AppKit
import BCRPluginHost
import BCRProviderApplication
import BCRProviderMCPAdapter
import enum SurfacePluginContracts.InputOrigin
import UniformTypeIdentifiers
import Combine
import Foundation

@MainActor
final class ConsoleDeviceWork: ObservableObject {
    let presentation: ConsolePresentationState
    private var ownerUpdates: [AnyCancellable] = []
    private let timing: ConsoleTiming
    let session: SurfaceSession
    let connectionWork: ConsoleConnectionWork
    let presetWork: ConsolePresetWork
    let recoveryWork: ConsoleRecoveryWork
    let buttonFeedbackWork: ConsoleButtonFeedbackWork
    private let surfaceIntents: ConsoleSurfaceIntents
    let mcp: MCPController
    let provider: ProviderApplication
    let feedbackSettings: FeedbackSettingsController
    let codex: CodexAgentController
    let library: ConfigurationLibrary
    let output: OutputController
    static let infoNoticeSeconds: Double = 6
    var canConfigureMIDI: Bool { connectionWork.canConfigureMIDI }
    var endpointSelection: MIDIEndpointSelection { connectionWork.endpointSelection }
    var endpointSettingsNeedRepair: Bool { connectionWork.endpointSettingsNeedRepair }
    var pendingHardwareConnection: HardwareConnectionPrompt? { connectionWork.pendingHardwareConnection }
    var observedHardwareGroup: Int? { connectionWork.observedHardwareGroup }
    var connectingHardware: Bool { connectionWork.connectingHardware }
    var startingMIDI: Bool { connectionWork.startingMIDI }
    var displayProfile: BCRDisplayProfile? { presetWork.displayProfile }
    var presetAlignment: PresetAlignmentState? { presetWork.presetAlignment }
    var pendingPresetNumberConfirmation: PresetNumberConfirmation? { presetWork.pendingPresetNumberConfirmation }
    var selectedPresetNumber: Int? { presetWork.selectedPresetNumber }
    var presetRestorePoint: PresetRestorePoint? { recoveryWork.presetRestorePoint }
    var blinksAgentLEDs: Bool { buttonFeedbackWork.blinksAgentLEDs }
    var mockAgents: BCRMockAgentHost? { buttonFeedbackWork.mockAgents }
    private var presetSourceSwitchBlocked: Bool { presetWork.presetSourceSwitchBlocked }
    private var hardwareSwitchWrites: Bool { connectionWork.hardwareSwitchWrites }
    private var hardwareConnectionConfirmation: HardwareConnectionConfirmation {
        connectionWork.hardwareConnectionConfirmation
    }

    var workspacePanels: WorkspacePanelSettings {
        get { presentation.workspacePanels } set { presentation.workspacePanels = newValue }
    }

    var pendingTouchedControl: BCRControlID? {
        get { presentation.pendingTouchedControl } set { presentation.pendingTouchedControl = newValue }
    }

    var uiPublishTask: Task<Void, Never>? {
        get { presentation.uiPublishTask } set { presentation.uiPublishTask = newValue }
    }

    var source: DeviceSource { session.source }

    var engine: SurfaceEngine { session.engine }

    var mock: MockBCR2000 { session.mock }

    var connection: MIDIConnectionSnapshot { session.connection }

    var events: [MonitorEvent] { session.events }

    var droppedFeedbackCount: Int { session.droppedFeedbackCount }

    var slots: [AgentSlotPresentation] { get { presentation.slots } set { presentation.slots = newValue } }

    var notice: ConsoleNotice? { get { presentation.notice } set { presentation.notice = newValue } }

    var noticeDismissTask: Task<Void, Never>? {
        get { presentation.noticeDismissTask } set { presentation.noticeDismissTask = newValue }
    }

    var persistenceNotice: ConsoleNotice? {
        get { presentation.persistenceNotice } set { presentation.persistenceNotice = newValue }
    }

    var visibleGroup: Int { get { presentation.visibleGroup } set { presentation.visibleGroup = newValue } }

    var display: BCRDisplayModel { get { presentation.display } set { presentation.display = newValue } }

    var displayMarquee: DisplayMarqueeState { presentation.displayMarquee }

    var displayRevertTask: Task<Void, Never>? {
        get { presentation.displayRevertTask } set { presentation.displayRevertTask = newValue }
    }

    var hardwarePressedControls: Set<BCRControlID> {
        get { presentation.hardwarePressedControls } set { presentation.hardwarePressedControls = newValue }
    }

    var pressTasks: [BCRControlID: Task<Void, Never>] {
        get { presentation.pressTasks } set { presentation.pressTasks = newValue }
    }

    var pressStarted: [BCRControlID: Double] {
        get { presentation.pressStarted } set { presentation.pressStarted = newValue }
    }

    var selectedControl: BCRControlID? {
        get { presentation.selectedControl } set { presentation.selectedControl = newValue }
    }

    var followsTouch: Bool { get { presentation.followsTouch } set { presentation.followsTouch = newValue } }

    var configuration: SurfaceConfiguration {
        engine.configuration
    }

    var isLearning: Bool {
        engine.learnTarget != nil
    }

    var learnedCount: Int {
        engine.hardwareMap.boundCount
    }

    var displayContent: BCRDisplayModel.Content {
        display.content(at: timing.presentation.now())
    }

    var displayText: String { BCRDisplayModel.text(for: displayContent) }

    var displayBusy: Bool { display.transfers > 0 }

    var displayTransferOperation: BCRDisplayModel.TransferOperation { display.transferOperation }

    var deviceActivity: Bool { get { presentation.deviceActivity } set { presentation.deviceActivity = newValue } }

    var activityTask: Task<Void, Never>? {
        get { presentation.activityTask } set { presentation.activityTask = newValue }
    }

    var backgroundTasks: [Task<Void, Never>] {
        connectionWork.backgroundTasks + presetWork.backgroundTasks +
            [recoveryWork.restoreTask, presentation.uiPublishTask].compactMap { $0 }
    }

    func waitForBackgroundWork(timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var finished = Set<Task<Void, Never>>()
        var idleChecks = 0
        while idleChecks < 3 {
            let running = backgroundTasks.filter { !finished.contains($0) }
            guard !running.isEmpty else {
                // Let callbacks already queued on the main actor start their tasks before concluding.
                idleChecks += 1
                await Task.yield()
                continue
            }
            idleChecks = 0
            for task in running {
                guard await Self.finishes(task, before: deadline) else {
                    throw BackgroundWorkTimeout(timeout: timeout)
                }
                finished.insert(task)
            }
        }
    }

    struct BackgroundWorkTimeout: Error, CustomStringConvertible {
        let timeout: Duration
        var description: String { "Background device work did not finish within \(timeout)" }
    }

    /// Races the task against the deadline without cancelling it. Not a task group: a group waits
    /// for every child, and awaiting a task's value does not end on cancellation.
    private static func finishes(_ task: Task<Void, Never>, before deadline: ContinuousClock.Instant) async -> Bool {
        @MainActor final class Race {
            var continuation: CheckedContinuation<Bool, Never>?
            func resolve(_ value: Bool) { continuation?.resume(returning: value); continuation = nil }
        }
        let race = Race()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            Task { @MainActor in await task.value; race.resolve(true) }
            Task { @MainActor in try? await Task.sleep(until: deadline, clock: .continuous); race.resolve(false) }
        }
    }

    init(stores: ConsoleStores = .standard, startsMIDI: Bool = true,
         mcpCredentials: (any MCPCredentialStore)? = nil, integrationTest: Bool = false,
         midiService: (any MIDIService)? = nil, outputTransport: (any OutputTransport)? = nil,
         initialPreset: ConfigurationPreset = .starter,
         codexFactory: (@MainActor () async throws -> CodexSessionCoordinator)? = nil,
         providerConfiguration: ProviderConfiguration = .init(),
         mockClock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
         automaticallyAdvancesMock: Bool = true,
         timing: ConsoleTiming = .init())
    {
        let ui = ConsolePresentationState(timing: timing, workspacePanelStore: JSONFileStore(fileURL:
            stores.configuration.fileURL.deletingLastPathComponent().appending(path: "workspace-panels.json")))
        presentation = ui
        self.timing = timing
        if integrationTest { IntegrationStartupLog.write("model.init.begin") }
        defer { if integrationTest { IntegrationStartupLog.write("model.init.ready") } }
        provider = ProviderApplication(configuration: providerConfiguration, monotonic: mockClock)
        codex = CodexAgentController(
            directory: stores.configuration.fileURL.deletingLastPathComponent(),
            factory: codexFactory
        )
        library = ConfigurationLibrary(url: stores.configuration.fileURL.deletingLastPathComponent()
            .appending(path: "configuration-library.json"))
        ui.slots = AgentSlotPresentation.mockSlots()

        let supportDirectory = stores.configuration.fileURL.deletingLastPathComponent()
        var migratedHardwareMap: HardwareMap?
        var migratedConfiguration = false
        let configurationFile = ProtectedJSONFile.configuration(stores.configuration, preset: initialPreset)
        let hardwareFile = ProtectedJSONFile.hardware(stores.hardwareMap)
        let mapRead = hardwareFile.load()
        let configRead = configurationFile.load()
        let loadedMap = mapRead.value
        let configuration = configRead.value
        let messages = [mapRead.message, configRead.message].compactMap { $0 }
        if !messages.isEmpty {
            let failed = mapRead.failed || configRead.failed
            // A message without a failure is a version migration held in memory only.
            if !failed {
                migratedHardwareMap = mapRead.message == nil ? nil : loadedMap
                migratedConfiguration = configRead.message != nil
            }
            ui.persistenceNotice = ConsoleNotice(level: failed ? .error : .info,
                                                 text: messages.joined(separator: " "),
                                                 action: failed ? nil : .saveMigration)
        }

        let endpointStore = JSONFileStore<MIDIEndpointSelection>(fileURL:
            stores.configuration.fileURL.deletingLastPathComponent().appending(path: "midi-endpoints.json"))
        let (savedSelection, endpointError) = ConsoleConnectionWork.readSelection(endpointStore)
        let workspacePanelStore = ui.workspacePanelStore
        var panelError: LocalizedMessage?
        do { if let stored = try workspacePanelStore.load() { ui.workspacePanels = stored } }
        catch { panelError = "面板设置读取失败，专业面板保持隐藏：\(error: error)" }
        let midi = midiService ?? CoreMIDIService(selection: savedSelection)
        session = SurfaceSession(
            hardwareDevice: midi, hardwareMap: loadedMap, configuration: configuration,
            pluginBindings: AgentBindingTranslation.bindings,
            requiresHardwareConfirmation: true,
            now: timing.intentNow, historyTime: timing.work,
            saveHardwareMap: { try hardwareFile.save($0) },
            saveConfiguration: { try configurationFile.save($0) }
        )
        feedbackSettings = FeedbackSettingsController(session: session,
                                                      url: stores.configuration.fileURL.deletingLastPathComponent()
                                                          .appending(path: "feedback-policy.json"))
        mcp = MCPController(session: session, store: JSONFileStore(fileURL:
            stores.configuration.fileURL.deletingLastPathComponent().appending(path: "mcp-settings.json")),
        credentials: mcpCredentials ?? KeychainMCPCredentialStore(),
        integrationTest: integrationTest, provider: provider)
        output = OutputController(session: session, store: JSONFileStore(fileURL:
            stores.configuration.fileURL.deletingLastPathComponent().appending(path: "output-settings.json")),
        adapter: outputTransport ?? OutputTransportRouter(), runtime: provider.runtime)
        let context = ConsoleDeviceContext(session: session, midi: midi, presentation: ui,
                                           timing: timing, canConfigureMIDI: startsMIDI, hardwareFile: hardwareFile)
        let gate = ConsolePresetOperationGate()
        let recoveryStore = ConsoleRecoveryStore(directory: supportDirectory)
        let presetWork = ConsolePresetWork(context: context, gate: gate, recoveryStore: recoveryStore,
                                           directory: supportDirectory)
        let recoveryWork = ConsoleRecoveryWork(context: context, preset: presetWork, gate: gate, store: recoveryStore)
        let connectionWork = ConsoleConnectionWork(context: context, endpointStore: endpointStore,
                                                   selection: savedSelection, endpointError: endpointError,
                                                   output: output, preset: presetWork, recovery: recoveryWork)
        let buttonFeedbackWork = ConsoleButtonFeedbackWork(context: context, codex: codex, directory: supportDirectory)
        let surfaceIntents = ConsoleSurfaceIntents(context: context, configurationFile: configurationFile,
                                                   migratedHardwareMap: migratedHardwareMap,
                                                   migratedConfiguration: migratedConfiguration)
        self.presetWork = presetWork; self.recoveryWork = recoveryWork
        self.connectionWork = connectionWork; self.buttonFeedbackWork = buttonFeedbackWork
        self.surfaceIntents = surfaceIntents
        presetWork.recovery = recoveryWork
        presetWork.isConnecting = { [weak connectionWork] in connectionWork?.connectingHardware ?? false }
        presetWork.isStarting = { [weak connectionWork] in connectionWork?.startingMIDI ?? false }
        recoveryWork.isConnecting = { [weak connectionWork] in connectionWork?.connectingHardware ?? false }
        surfaceIntents.requestSource = { [weak connectionWork] in connectionWork?.requestSource($0) }
        surfaceIntents.canChangeButtonFunctions = { [weak connectionWork, weak presetWork] in
            connectionWork?.canConfigureMIDI == true && connectionWork?.source == .hardware &&
                connectionWork?.connection.isConnected == true && connectionWork?.isLearning == false &&
                connectionWork?.connectingHardware == false && presetWork?.presetAlignment?.phase.isBusy != true
        }
        do { try ProviderMCPModule.install(on: mcp.service, application: provider) }
        catch { preconditionFailure("Invalid built-in provider module registration") }
        provider.start()
        midi.observeTransferLines { [weak self] direction in self?.displayMarquee.step(direction) }
        mcp.service.onReadAgents = { [weak self] in
            guard let self else { throw MCPToolFailure(L10n.text("Agent 服务不可用")) }
            return .object([
                "backend": .string(self.codex.backend.rawValue),
                "slots": try AgentSlotArchive.json(self.slots)
            ])
        }
        mcp.service.onAgentAction = { [weak self] action, slot in
            guard let self else { throw MCPToolFailure(L10n.text("Agent 服务不可用")) }
            if self.codex.backend == .mock { _ = try self.requireMockHost() }
            if action == "stop_all_agents" {
                if self.codex.backend == .mock {
                    for slot in self.slots where slot.state.isActive { self.interrupt(slot.id) }
                }
                Task { await self.codex.stopAll() }
                return
            }
            guard let slot, let current = self.slots.first(where: { $0.id == slot }) else {
                throw MCPToolFailure(L10n.text("Agent 槽位必须为 1–8"))
            }
            if action == "start_agent" {
                if self.codex.backend == .codex {
                    guard self.codex.phase == .ready,
                          !self.codex.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { throw MCPToolFailure(L10n.text("Codex 连接未建立")) }
                }
                guard !current.state.isActive else {
                    throw MCPToolFailure(L10n.text("Agent 正忙"))
                }
                self.start(slot, origin: .remote)
            } else { self.interrupt(slot) }
        }
        mcp.service.onReadHardwareConnectionConfirmation = { [weak self] in
            self?.hardwareConnectionConfirmation ?? .none
        }
        mcp.service.onReadMIDIEndpointSelection = { [weak self] in self?.endpointSelection ?? .init() }
        mcp.service.onSelectMIDIEndpoints = { [weak self] selection in
            guard let self else { throw MCPToolFailure(L10n.text("MIDI 端口设置服务不可用")) }
            guard self.canConfigureMIDI else { throw MCPToolFailure(L10n.text("隔离测试未启用实体 MIDI")) }
            guard !self.presetSourceSwitchBlocked else {
                throw MCPToolFailure(L10n.text("预设操作尚未结束，暂不能更改 MIDI 端口。"))
            }
            guard !self.startingMIDI else { throw MCPToolFailure(L10n.text("MIDI 服务仍在启动，请等待设备就绪。")) }
            try self.commitEndpointSelection(selection)
        }
        mcp.service.onPresetAlignment = { [weak self] command in
            guard let self else { throw MCPToolFailure(L10n.text("预设对齐服务不可用")) }
            guard self.canConfigureMIDI else { throw MCPToolFailure(L10n.text("隔离测试未启用实体 MIDI")) }
            return try self.handlePresetAlignment(command)
        }
        mcp.service.onSelectSource = { [weak self] source in
            guard let self else { throw MCPToolFailure(L10n.text("设备切换服务不可用")) }
            guard !self.presetSourceSwitchBlocked else {
                throw MCPToolFailure(L10n.text("预设操作尚未结束，暂不能切换设备来源。"))
            }
            if source == .hardware, self.startingMIDI {
                throw MCPToolFailure(L10n.text("MIDI 服务仍在启动，请等待设备就绪。"))
            }
            if source == .hardware, !self.canConfigureMIDI { throw MCPToolFailure(L10n.text("隔离测试未启用实体 MIDI")) }
            guard source == .hardware, self.source == .mock, self.hardwareSwitchWrites else {
                self.selectSource(source); return
            }
            // Remote callers cannot choose the sync direction; the user confirms in the window.
            self.offerHardwareConnection()
            throw MCPToolFailure(L10n.text("连接实体设备需要在界面上确认同步方向；确认前保持 Mock。"))
        }
        codex.onStopMock = { [weak self] in
            guard let self else { return }
            do { try self.requireMockHost().reset(started: self.codex.backend == .mock) } catch { self.report(error) }
        }
        codex.onSlots = { [weak self] slots in
            guard let self else { return }
            for slot in slots { self.applyAgentSlots(slots, changed: slot.id) }
        }
        ui.isStartingMIDI = { [weak self] in self?.startingMIDI ?? false }
        ui.selectGroup = { [weak self] in self?.selectGroup($0) }
        ownerUpdates = [ui.objectWillChange, connectionWork.objectWillChange, presetWork.objectWillChange,
                        recoveryWork.objectWillChange, recoveryStore.objectWillChange,
                        buttonFeedbackWork.objectWillChange]
            .map { publisher in publisher.sink { [weak self] _ in self?.objectWillChange.send() } }
        session.onChange = { [weak self] in
            guard let self else { return }
            self.presetWork.validateConnectionWork()
            self.recoveryWork.validateConnectionWork()
            self.connectionWork.validateConnectionWork()
            self.presentation.scheduleFrame()
        }
        session.onEvent = { [weak self] in self?.handleSessionEvent($0) }
        session.onTriggerAction = { [weak self] action in
            guard let self else { return }
            do { self.performSurfaceAgentAction(try AgentBindingTranslation.slot(for: action)) }
            catch { self.report(error) }
        }
        if integrationTest {
            notice = ConsoleNotice(level: .info, message: "隔离集成测试：使用独立配置与内存凭据，不连接实体设备。")
        }
        do {
            let host = try BCRMockAgentHost(
                clock: mockClock,
                runtime: provider.runtime,
                started: codex.backend == .mock
            )
            buttonFeedbackWork.installMockHost(host)
            if codex.backend == .mock { slots = try host.slots }
            host.onError = { [weak self] in self?.report($0) }
            host.onUpdate = { [weak self] slots, feedback in
                guard let self, self.codex.backend == .mock else { return }
                let previous = Dictionary(uniqueKeysWithValues: self.slots.map { ($0.id, $0.state) })
                self.slots = slots
                for slot in slots where previous[slot.id] != slot.state {
                    if let value = feedback[slot.id] { self.buttonFeedbackWork.showAgentState(slot, level: value) }
                }
            }
            if automaticallyAdvancesMock { host.startDriving() }
        } catch { report(error) }
        do { try ProviderMCPModule.installShared(on: mcp.service, application: provider) }
        catch { report(error) }
        session.synchronize()
        Task { @MainActor [weak mcp] in await mcp?.restore() }
        Task { @MainActor [weak output] in output?.restore() }
        if let panelError { notice = ConsoleNotice(level: .error, message: panelError) }
        if let endpointError {
            let panel = panelError ?? .verbatim("")
            notice = ConsoleNotice(level: .error, message: "\(panel) \(endpointError)")
            return
        }
        if let point = presetRestorePoint, point != point.bounded() {
            do { try recoveryStore.saveRestorePoint(point) } catch { report(error) }
        }
        guard startsMIDI else { return }
        connectionWork.start()
    }

    func handlePresetAlignment(_ command: PresetAlignmentCommand) throws -> SurfacePluginContracts.JSONValue {
        try ConsolePresetMCP(preset: presetWork, recovery: recoveryWork).handlePresetAlignment(command)
    }

    func applyEndpointSelection(_ selection: MIDIEndpointSelection) { connectionWork.applyEndpointSelection(selection) }
    func commitEndpointSelection(_ selection: MIDIEndpointSelection) throws {
        try connectionWork.commitEndpointSelection(selection)
    }

    func selectSource(_ newSource: DeviceSource) { connectionWork.selectSource(newSource) }
    func offerHardwareConnection() { connectionWork.offerHardwareConnection() }
    func requestSource(_ newSource: DeviceSource) { connectionWork.requestSource(newSource) }
    func declineHardwareConnection(_ id: UUID) { connectionWork.declineHardwareConnection(id) }
    func connectHardware(_ id: UUID, mode: HardwareConnectionPrompt.Mode) { connectionWork.connectHardware(
        id,
        mode: mode
    ) }
    func requestPresetNumberConfirmation() { presetWork.requestPresetNumberConfirmation() }
    func selectDisplayPresetNumber(_ id: UUID, number: Int) { presetWork.selectDisplayPresetNumber(id, number: number) }
    func confirmDisplayPresetNumber(_ id: UUID, number: Int) {
        presetWork.confirmDisplayPresetNumber(id, number: number)
    }

    func cancelPresetNumberConfirmation() { presetWork.cancelPresetNumberConfirmation() }
    func beginPresetAlignment(options: BCRPresetAlignment.Options = .init()) {
        presetWork.beginPresetAlignment(options: options)
    }

    func setAlignmentOptions(_ options: BCRPresetAlignment.Options) { presetWork.setAlignmentOptions(options) }
    func applyPresetAlignment() { presetWork.applyPresetAlignment() }
    func dismissPresetAlignment() { presetWork.dismissPresetAlignment() }
    func restorePresetBeforeAlignment() { recoveryWork.restorePresetBeforeAlignment() }
    func confirmPresetRestoreReplacingLearning() { recoveryWork.confirmPresetRestoreReplacingLearning() }
    func cancelPresetRestore() { recoveryWork.cancelPresetRestore() }
    func discardPresetRestore(_ confirmed: PresetRestorePoint) { recoveryWork.discardPresetRestore(confirmed) }
    func revealPresetBackups(file: URL? = nil) { recoveryWork.revealPresetBackups(file: file) }
    func applyAgentSlots(_ newSlots: [AgentSlotPresentation], changed slotID: AgentSlotID) {
        buttonFeedbackWork.applyAgentSlots(
            newSlots,
            changed: slotID
        )
    }

    func setBlinksAgentLEDs(_ enabled: Bool) { buttonFeedbackWork.setBlinksAgentLEDs(enabled) }
    func showSurfaceApprovalNotice() { buttonFeedbackWork.showSurfaceApprovalNotice() }
    func selectGroup(_ group: Int) { surfaceIntents.selectGroup(group) }
    func turn(_ control: BCRControlID, by delta: Int) { surfaceIntents.turn(control, by: delta) }
    func press(_ control: BCRControlID) { surfaceIntents.press(control) }
    func release(_ control: BCRControlID) { surfaceIntents.release(control) }
    func touch(_ control: BCRControlID) { surfaceIntents.touch(control) }
    func setParameter(_ id: ParameterID, to value: Double) { surfaceIntents.setParameter(id, to: value) }
    func resetGroup(_ group: String) { surfaceIntents.resetGroup(group) }
    func undo() { surfaceIntents.undo() }
    func redo() { surfaceIntents.redo() }
    func recallScene(_ id: String) { surfaceIntents.recallScene(id) }
    func deleteScene(_ id: String) { surfaceIntents.deleteScene(id) }
    func renameScene(_ id: String, to name: String) { surfaceIntents.renameScene(id, to: name) }
    func captureScene(name: String, overwrite: Bool = false) { surfaceIntents.captureScene(
        name: name,
        overwrite: overwrite
    ) }
    @discardableResult
    func createParameter(assigningTo control: BCRControlID? = nil) -> ParameterID? { surfaceIntents
        .createParameter(assigningTo: control)
    }

    @discardableResult
    func updateParameter(_ definition: ParameterDefinition) -> ParameterDefinition? { surfaceIntents
        .updateParameter(definition)
    }

    func removeParameter(_ id: ParameterID) { surfaceIntents.removeParameter(id) }
    func loadPreset(_ preset: ConfigurationPreset) { surfaceIntents.loadPreset(preset) }
    func setAssignment(_ assignment: ControlAssignment?, for control: BCRControlID) { surfaceIntents.setAssignment(
        assignment,
        for: control
    ) }
    func setCycleValues(_ text: String, parameter: ParameterID, for control: BCRControlID) {
        surfaceIntents.setCycleValues(
            text,
            parameter: parameter,
            for: control
        )
    }

    func bulkAssignmentPlan(section: BCRSection, row: Int,
                            group: String) -> BulkAssignmentPlan?
    { surfaceIntents.bulkAssignmentPlan(
        section: section,
        row: row,
        group: group
    ) }
    @discardableResult
    func applyBulkAssignment(_ plan: BulkAssignmentPlan) -> Bool { surfaceIntents.applyBulkAssignment(plan) }
    func beginLearning(at control: BCRControlID, format: MIDILearnFormat = .voice) { surfaceIntents.beginLearning(
        at: control,
        format: format
    ) }
    func parameterFractionDigits(_ id: ParameterID) -> Int { surfaceIntents.parameterFractionDigits(id) }
    func setMockNRPN(_ enabled: Bool, for control: BCRControlID) { surfaceIntents.setMockNRPN(enabled, for: control) }
    func stopLearning() { surfaceIntents.stopLearning() }
    func unbind(_ control: BCRControlID) { surfaceIntents.unbind(control) }
    func setHardwareButtonFunctions(_ entry: HardwareMapEntry, enabled: Bool) {
        surfaceIntents.setHardwareButtonFunctions(
            entry,
            enabled: enabled
        )
    }

    func resetHardwareMap() { surfaceIntents.resetHardwareMap() }
    func clearMonitor() { surfaceIntents.clearMonitor() }
    func clearNotice() { surfaceIntents.clearNotice() }
    func clearPersistenceNotice() { surfaceIntents.clearPersistenceNotice() }
    func performNoticeAction(_ action: ConsoleNotice.Action) { surfaceIntents.performNoticeAction(action) }
    func selectPage(_ id: String) throws { try surfaceIntents.selectPage(id) }
    func updatePrograms(_ candidate: SurfaceConfiguration) throws { try surfaceIntents.updatePrograms(candidate) }
    func readConfiguration(from url: URL) throws -> SurfaceConfiguration { try surfaceIntents
        .readConfiguration(from: url)
    }

    @discardableResult
    func installConfiguration(_ candidate: SurfaceConfiguration) -> Bool { surfaceIntents
        .installConfiguration(candidate)
    }

    func chooseConfigurationImport() async -> SurfaceConfiguration? { await surfaceIntents.chooseConfigurationImport() }
    func exportConfiguration(to url: URL) throws { try surfaceIntents.exportConfiguration(to: url) }
    func chooseConfigurationExport() async { await surfaceIntents.chooseConfigurationExport() }
    func displayValue(of control: BCRControlID) -> UInt8 {
        switch source {
        case .mock: mock.value(of: control)
        case .hardware: engine.state(of: control).value
        }
    }

    func slot(_ id: AgentSlotID) -> AgentSlotPresentation? {
        slots.first { $0.id == id }
    }

    var deviceKeysLocked: Bool? { presetWork.deviceKeysLocked }
    var displayPresetName: String? { presetWork.displayPresetName }
    var canCheckDisplayPresetNumber: Bool { presetWork.canCheckDisplayPresetNumber }
    var canAlignPreset: Bool { presetWork.canAlignPreset }
    var restoreUnavailableReason: String? { recoveryWork.restoreUnavailableReason }
    var canRestorePreset: Bool { recoveryWork.canRestorePreset }
    var canDiscardPresetRestore: Bool { recoveryWork.canDiscardPresetRestore }
    var canRevealPresetBackups: Bool { recoveryWork.canRevealPresetBackups }
    var canChangeHardwareButtonFunctions: Bool { surfaceIntents.canChangeButtonFunctions() }
    func performPrimaryAction(_ slotID: AgentSlotID) { buttonFeedbackWork.performPrimaryAction(slotID) }
    func performSurfaceAgentAction(_ slotID: AgentSlotID) { buttonFeedbackWork.performSurfaceAgentAction(slotID) }
    func start(_ slotID: AgentSlotID, origin: InputOrigin = .interface) { buttonFeedbackWork.start(
        slotID,
        origin: origin
    ) }
    func interrupt(_ slotID: AgentSlotID) { buttonFeedbackWork.interrupt(slotID) }
    func approve(_ slotID: AgentSlotID) { buttonFeedbackWork.approve(slotID) }
    func decline(_ slotID: AgentSlotID) { buttonFeedbackWork.decline(slotID) }
    func requireMockHost() throws -> BCRMockAgentHost { try buttonFeedbackWork.requireMockHost() }
    private func handleSessionEvent(_ event: SurfaceSessionEvent) {
        switch event {
        case .pageChanged:
            if notice?.level != .error, let warning = configuration
                .pageNavigationWarning { notice = ConsoleNotice(level: .warning, text: warning) }
        case let .sourceChanged(source):
            // The session may leave hardware on its own (e.g. route loss); no held press survives that.
            clearHardwarePresses()
            if source == .hardware { presetWork.refreshDisplayFromDevice() }
            else {
                presetWork.cancelDisplayReadAndClearNumberContext()
            }
            switch source {
            case .mock:
                notice = ConsoleNotice(level: .info, message: "已切换到 Mock 设备：在虚拟面板上拖动旋钮、按下按键即模拟实体操作。")
            case .hardware:
                notice = connection.isConnected
                    ? ConsoleNotice(level: .info, message: "已切换到实体 BCR2000，软件状态已整体回写。")
                    : ConsoleNotice(level: .warning, message: "已切换到实体模式，但尚未找到 BCR2000 Port 1。")
            }
        case let .connected(snapshot):
            connectionWork.clearObservedGroup()
            presetWork.clearNumberContext()
            presetWork.invalidateDisplayNumber()
            clearDisplayedValue()
            clearHardwarePresses()
            offerHardwareConnection()
            if connectionWork.hasConnectionOffer || connectingHardware { return }
            if source == .hardware {
                notice = ConsoleNotice(
                    level: .info,
                    message: "已连接 \(snapshot.connectedSource ?? "BCR2000")，软件状态已整体回写。"
                )
            } else {
                notice = ConsoleNotice(
                    level: .info,
                    message: "检测到 \(snapshot.connectedSource ?? "BCR2000")。当前仍在 Mock 模式，实体输入只记录不执行。",
                    action: .switchToHardware
                )
            }
        case let .touched(control):
            connectionWork.noteTouched(control)
            guard followsTouch else { return }
            pendingTouchedControl = control
        case let .deviceInput(control, rawValue, pressed):
            if source == .hardware { noteDeviceActivity() }
            showDeviceInput(control, rawValue: rawValue, pressed: pressed)
        case let .buttonActivity(control, pressed):
            guard source == .hardware else { return }
            presentation.noteButtonActivity(control, pressed: pressed)
        case let .learningInterruptedByConfiguration(control):
            let previous = notice?.localizedMessage ?? .verbatim("")
            let stopped: LocalizedMessage = " 配置替换已停止 \(control.shortName) 的学习。"
            notice = ConsoleNotice(level: notice?.level ?? .info,
                                   message: "\(previous)\(stopped)", action: notice?.action)
        case let .learned(control, midi, next):
            selectedControl = next ?? control
            notice = ConsoleNotice(level: .info, message: next.map { next -> LocalizedMessage in
                "\(control.shortName) = \(midi)。下一个：请操作 \(next.shortName)。"
            } ?? "\(control.shortName) = \(midi)。本区已全部学习，学习结束。")
        case let .learnRejected(_, error):
            notice = ConsoleNotice(level: .warning, message: "\(error: error)")
        case let .failed(operation, message):
            let prefix: LocalizedMessage
            switch operation {
            case .feedback: prefix = "反馈发送失败"
            case .hardwareMapPersistence: prefix = "硬件映射保存失败"
            case .configurationPersistence: prefix = "功能配置保存失败"
            case .hardwareInput: prefix = "实体输入被拒绝"
            }
            notice = ConsoleNotice(level: .error, message: "\(prefix)：\(message)",
                                   action: operation == .configurationPersistence ? .retryConfigurationSave : nil)
        }
    }

    func report(_ error: Error) {
        notice = ConsoleNotice(level: .error, message: "\(error: error)")
    }

    func setWorkspacePanel(_ panel: WorkspaceTab, enabled: Bool) -> Bool { presentation.setWorkspacePanel(
        panel,
        enabled: enabled
    ) }
    private func noteDeviceActivity() { presentation.noteDeviceActivity() }

    private func clearDisplayedValue() { presentation.clearDisplayedValue() }

    private func clearHardwarePresses() { presentation.clearHardwarePresses() }

    private func showDeviceInput(_ control: BCRControlID, rawValue: UInt16, pressed: Bool?) {
        let shows = source == .mock || (displayProfile?.showsValue(control) ?? true)
        presentation.showDeviceInput(control, rawValue: rawValue, pressed: pressed, shows: shows)
    }
}
