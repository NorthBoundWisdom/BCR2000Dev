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
import enum SurfacePluginContracts.IndicatorSemantic
import enum SurfacePluginContracts.InputOrigin
import UniformTypeIdentifiers
import Combine
import Foundation

/// Stable UI surface: computed observations and intents delegate to the real work/state owners.
@dynamicMemberLookup
@MainActor
final class ConsoleViewModel: ObservableObject {
    @Published private(set) var deviceWork: ConsoleDeviceWork
    private var updates: AnyCancellable?
    static let infoNoticeSeconds = ConsoleDeviceWork.infoNoticeSeconds
    typealias BackgroundWorkTimeout = ConsoleDeviceWork.BackgroundWorkTimeout
    subscript<Value>(dynamicMember keyPath: KeyPath<ConsoleDeviceWork, Value>) -> Value { deviceWork[keyPath: keyPath] }
    var selectedControl: BCRControlID? {
        get { deviceWork.selectedControl } set { deviceWork.selectedControl = newValue }
    }

    var followsTouch: Bool { get { deviceWork.followsTouch } set { deviceWork.followsTouch = newValue } }
    var canConfigureMIDI: Bool { deviceWork.canConfigureMIDI }
    var endpointSelection: MIDIEndpointSelection { deviceWork.endpointSelection }
    var endpointSettingsNeedRepair: Bool { deviceWork.endpointSettingsNeedRepair }
    var workspacePanels: WorkspacePanelSettings { deviceWork.workspacePanels }
    var mcp: MCPController { deviceWork.mcp }
    var provider: ProviderApplication { deviceWork.provider }
    var feedbackSettings: FeedbackSettingsController { deviceWork.feedbackSettings }
    var codex: CodexAgentController { deviceWork.codex }
    var library: ConfigurationLibrary { deviceWork.library }
    var output: OutputController { deviceWork.output }
    var source: DeviceSource { deviceWork.source }
    var engine: SurfaceEngine { deviceWork.engine }
    var mock: MockBCR2000 { deviceWork.mock }
    var connection: MIDIConnectionSnapshot { deviceWork.connection }
    var events: [MonitorEvent] { deviceWork.events }
    var droppedFeedbackCount: Int { deviceWork.droppedFeedbackCount }
    var slots: [AgentSlotPresentation] { deviceWork.slots }
    var notice: ConsoleNotice? { deviceWork.notice }
    var persistenceNotice: ConsoleNotice? { deviceWork.persistenceNotice }
    var visibleGroup: Int { deviceWork.visibleGroup }
    var pendingHardwareConnection: HardwareConnectionPrompt? { deviceWork.pendingHardwareConnection }
    var display: BCRDisplayModel { deviceWork.display }
    var displayMarquee: DisplayMarqueeState { deviceWork.displayMarquee }
    var displayProfile: BCRDisplayProfile? { deviceWork.displayProfile }
    var observedHardwareGroup: Int? { deviceWork.observedHardwareGroup }
    var connectingHardware: Bool { deviceWork.connectingHardware }
    var presetAlignment: PresetAlignmentState? { deviceWork.presetAlignment }
    var blinksAgentLEDs: Bool { deviceWork.blinksAgentLEDs }
    var presetRestorePoint: PresetRestorePoint? { deviceWork.presetRestorePoint }
    var hardwarePressedControls: Set<BCRControlID> { deviceWork.hardwarePressedControls }
    var startingMIDI: Bool { deviceWork.startingMIDI }
    var mockAgents: BCRMockAgentHost? { deviceWork.mockAgents }
    var configuration: SurfaceConfiguration { deviceWork.configuration }
    var isLearning: Bool { deviceWork.isLearning }
    var learnedCount: Int { deviceWork.learnedCount }
    var displayContent: BCRDisplayModel.Content { deviceWork.displayContent }
    var displayText: String { deviceWork.displayText }
    var displayBusy: Bool { deviceWork.displayBusy }
    var displayTransferOperation: BCRDisplayModel.TransferOperation { deviceWork.displayTransferOperation }
    var deviceKeysLocked: Bool? { deviceWork.deviceKeysLocked }
    var deviceActivity: Bool { deviceWork.deviceActivity }
    var displayPresetName: String? { deviceWork.displayPresetName }
    var pendingPresetNumberConfirmation: PresetNumberConfirmation? { deviceWork.pendingPresetNumberConfirmation }
    var selectedPresetNumber: Int? { deviceWork.selectedPresetNumber }
    var canCheckDisplayPresetNumber: Bool { deviceWork.canCheckDisplayPresetNumber }
    var canChangeHardwareButtonFunctions: Bool { deviceWork.canChangeHardwareButtonFunctions }
    var canAlignPreset: Bool { deviceWork.canAlignPreset }
    var restoreUnavailableReason: String? { deviceWork.restoreUnavailableReason }
    var canRestorePreset: Bool { deviceWork.canRestorePreset }
    var canDiscardPresetRestore: Bool { deviceWork.canDiscardPresetRestore }
    var canRevealPresetBackups: Bool { deviceWork.canRevealPresetBackups }
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
        deviceWork = ConsoleDeviceWork(stores: stores, startsMIDI: startsMIDI, mcpCredentials: mcpCredentials,
                                       integrationTest: integrationTest, midiService: midiService,
                                       outputTransport: outputTransport,
                                       initialPreset: initialPreset, codexFactory: codexFactory,
                                       providerConfiguration: providerConfiguration,
                                       mockClock: mockClock, automaticallyAdvancesMock: automaticallyAdvancesMock,
                                       timing: timing)
        updates = deviceWork.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func waitForBackgroundWork(timeout: Duration = .seconds(10)) async throws {
        try await deviceWork.waitForBackgroundWork(timeout: timeout)
    }

    func displayValue(of control: BCRControlID) -> UInt8 { deviceWork.displayValue(of: control) }
    func slot(_ id: AgentSlotID) -> AgentSlotPresentation? { deviceWork.slot(id) }
    @discardableResult
    func setWorkspacePanel(_ panel: WorkspaceTab, enabled: Bool) -> Bool { deviceWork.setWorkspacePanel(
        panel,
        enabled: enabled
    ) }
    func applyEndpointSelection(_ selection: MIDIEndpointSelection) { deviceWork.applyEndpointSelection(selection) }
    func selectSource(_ newSource: DeviceSource) { deviceWork.selectSource(newSource) }
    func requestPresetNumberConfirmation() { deviceWork.requestPresetNumberConfirmation() }
    func selectDisplayPresetNumber(_ id: UUID, number: Int) { deviceWork.selectDisplayPresetNumber(id, number: number) }
    func confirmDisplayPresetNumber(_ id: UUID, number: Int) {
        deviceWork.confirmDisplayPresetNumber(id, number: number)
    }

    func cancelPresetNumberConfirmation() { deviceWork.cancelPresetNumberConfirmation() }
    func selectGroup(_ group: Int) { deviceWork.selectGroup(group) }
    func turn(_ control: BCRControlID, by delta: Int) { deviceWork.turn(control, by: delta) }
    func press(_ control: BCRControlID) { deviceWork.press(control) }
    func release(_ control: BCRControlID) { deviceWork.release(control) }
    func touch(_ control: BCRControlID) { deviceWork.touch(control) }
    func setParameter(_ id: ParameterID, to value: Double) { deviceWork.setParameter(id, to: value) }
    func resetGroup(_ group: String) { deviceWork.resetGroup(group) }
    var canUndo: Bool { deviceWork.session.canUndo }
    var canRedo: Bool { deviceWork.session.canRedo }
    func undo() { deviceWork.undo() }
    func redo() { deviceWork.redo() }
    @discardableResult
    func createParameter(assigningTo control: BCRControlID? = nil) -> ParameterID? { deviceWork
        .createParameter(assigningTo: control)
    }

    @discardableResult
    func updateParameter(_ definition: ParameterDefinition) -> ParameterDefinition? { deviceWork
        .updateParameter(definition)
    }

    func removeParameter(_ id: ParameterID) { deviceWork.removeParameter(id) }
    func loadPreset(_ preset: ConfigurationPreset) { deviceWork.loadPreset(preset) }
    func setAssignment(_ assignment: ControlAssignment?, for control: BCRControlID) { deviceWork.setAssignment(
        assignment,
        for: control
    ) }
    func setCycleValues(_ text: String, parameter: ParameterID, for control: BCRControlID) { deviceWork.setCycleValues(
        text,
        parameter: parameter,
        for: control
    ) }
    func bulkAssignmentPlan(section: BCRSection, row: Int,
                            group: String) -> BulkAssignmentPlan?
    { deviceWork.bulkAssignmentPlan(
        section: section,
        row: row,
        group: group
    ) }
    @discardableResult
    func applyBulkAssignment(_ plan: BulkAssignmentPlan) -> Bool { deviceWork.applyBulkAssignment(plan) }
    func beginLearning(at control: BCRControlID, format: MIDILearnFormat = .voice) { deviceWork.beginLearning(
        at: control,
        format: format
    ) }
    func parameterFractionDigits(_ id: ParameterID) -> Int { deviceWork.parameterFractionDigits(id) }
    func setMockNRPN(_ enabled: Bool, for control: BCRControlID) { deviceWork.setMockNRPN(enabled, for: control) }
    func stopLearning() { deviceWork.stopLearning() }
    func unbind(_ control: BCRControlID) { deviceWork.unbind(control) }
    func setHardwareButtonFunctions(_ entry: HardwareMapEntry, enabled: Bool) { deviceWork.setHardwareButtonFunctions(
        entry,
        enabled: enabled
    ) }
    func resetHardwareMap() { deviceWork.resetHardwareMap() }
    func clearMonitor() { deviceWork.clearMonitor() }
    func clearNotice() { deviceWork.clearNotice() }
    func clearPersistenceNotice() { deviceWork.clearPersistenceNotice() }
    func performNoticeAction(_ action: ConsoleNotice.Action) { deviceWork.performNoticeAction(action) }
    func selectPage(_ id: String) throws { try deviceWork.selectPage(id) }
    func updatePrograms(_ candidate: SurfaceConfiguration) throws { try deviceWork.updatePrograms(candidate) }
    func readConfiguration(from url: URL) throws -> SurfaceConfiguration { try deviceWork.readConfiguration(from: url) }
    @discardableResult
    func installConfiguration(_ candidate: SurfaceConfiguration) -> Bool { deviceWork.installConfiguration(candidate) }
    func chooseConfigurationImport() async -> SurfaceConfiguration? { await deviceWork.chooseConfigurationImport() }
    func exportConfiguration(to url: URL) throws { try deviceWork.exportConfiguration(to: url) }
    func chooseConfigurationExport() async { await deviceWork.chooseConfigurationExport() }
    func beginPresetAlignment(options: BCRPresetAlignment.Options = .init()) {
        deviceWork.beginPresetAlignment(options: options)
    }

    func setAlignmentOptions(_ options: BCRPresetAlignment.Options) { deviceWork.setAlignmentOptions(options) }
    func applyPresetAlignment() { deviceWork.applyPresetAlignment() }
    func restorePresetBeforeAlignment() { deviceWork.restorePresetBeforeAlignment() }
    func confirmPresetRestoreReplacingLearning() { deviceWork.confirmPresetRestoreReplacingLearning() }
    func cancelPresetRestore() { deviceWork.cancelPresetRestore() }
    func discardPresetRestore(_ confirmed: PresetRestorePoint) { deviceWork.discardPresetRestore(confirmed) }
    func dismissPresetAlignment() { deviceWork.dismissPresetAlignment() }
    func revealPresetBackups(file: URL? = nil) { deviceWork.revealPresetBackups(file: file) }
    func requestSource(_ newSource: DeviceSource) { deviceWork.requestSource(newSource) }
    func declineHardwareConnection(_ id: UUID) { deviceWork.declineHardwareConnection(id) }
    func connectHardware(_ id: UUID, mode: HardwareConnectionPrompt.Mode) { deviceWork.connectHardware(id, mode: mode) }
    func applyAgentSlots(_ newSlots: [AgentSlotPresentation], changed slotID: AgentSlotID) { deviceWork.applyAgentSlots(
        newSlots,
        changed: slotID
    ) }
    func setBlinksAgentLEDs(_ enabled: Bool) { deviceWork.setBlinksAgentLEDs(enabled) }
    func showSurfaceApprovalNotice() { deviceWork.showSurfaceApprovalNotice() }
    func report(_ error: Error) { deviceWork.report(error) }
    func performPrimaryAction(_ slotID: AgentSlotID) { deviceWork.performPrimaryAction(slotID) }
    func performSurfaceAgentAction(_ slotID: AgentSlotID) { deviceWork.performSurfaceAgentAction(slotID) }
    func start(_ slotID: AgentSlotID, origin: InputOrigin = .interface) { deviceWork.start(slotID, origin: origin) }
    func interrupt(_ slotID: AgentSlotID) { deviceWork.interrupt(slotID) }
    func approve(_ slotID: AgentSlotID) { deviceWork.approve(slotID) }
    func decline(_ slotID: AgentSlotID) { deviceWork.decline(slotID) }
    func requireMockHost() throws -> BCRMockAgentHost { try deviceWork.requireMockHost() }
    func handlePresetAlignment(_ command: PresetAlignmentCommand) throws -> JSONValue { try deviceWork
        .handlePresetAlignment(command)
    }
}
