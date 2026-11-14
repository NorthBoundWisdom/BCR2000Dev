import AppKit
import BCRAgentCore
import BCRPluginHost
import BCRProviderApplication
import BCRProviderMCPAdapter
import enum SurfacePluginContracts.IndicatorSemantic
import UniformTypeIdentifiers
import Combine
import Foundation

extension DeviceSource {
    var title: String {
        switch self {
        case .mock: L10n.text("Mock 设备")
        case .hardware: L10n.text("实体 BCR2000")
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
        case retryConfigurationSave
        /// Write migrated files back (the originals are backed up first) so the notice stops recurring.
        case saveMigration
    }

    private enum Content: Equatable {
        case verbatim(String)
        case localized(LocalizedMessage)
    }

    let level: Level
    private let content: Content
    var action: Action?
    var localizedMessage: LocalizedMessage {
        switch content {
        case let .verbatim(text): .verbatim(text)
        case let .localized(message): message
        }
    }

    var text: String {
        switch content {
        case let .verbatim(text): text
        case let .localized(message): L10n.text(message)
        }
    }

    init(level: Level, text: String, action: Action? = nil) {
        self.level = level; content = .verbatim(text); self.action = action
    }

    init(level: Level, message: LocalizedMessage, action: Action? = nil) {
        self.level = level; content = .localized(message); self.action = action
    }
}

/// Read → preview → confirm → write → verify of the device's temporary preset.
struct PresetAlignmentState {
    enum Phase: Equatable {
        case reading, preview, writing(done: Int, total: Int), verifying, finished, restoring, restoreConfirmation,
             failed(LocalizedMessage)
        var isBusy: Bool {
            switch self {
            case .reading, .writing, .verifying, .restoring: true
            case .preview, .finished, .restoreConfirmation, .failed: false
            }
        }
    }

    var phase: Phase
    var options = BCRPresetAlignment.Options()
    var plan: BCRPresetAlignment.Plan?
    var planError: LocalizedMessage?
    var backup: URL?
    var canRestore = false
    var restoreProgress: (done: Int, total: Int)?
}

struct HardwareConnectionPrompt: Identifiable {
    enum Mode: Equatable { case initialize, write, read }
    let id = UUID()
    let route: MIDIConnectionSnapshot
    let program: MIDIStartupProgram?
    let canRead: Bool
    /// Without a startup program the user may still choose to write software values into the loaded preset.
    var canWrite: Bool { program == nil }
}

@MainActor
final class ConsoleViewModel: ObservableObject {
    private let midi: any MIDIService
    private let endpointStore: JSONFileStore<MIDIEndpointSelection>
    let canConfigureMIDI: Bool
    @Published private(set) var endpointSelection = MIDIEndpointSelection()
    /// Saved endpoint settings could not be read; MIDI stays stopped until a choice is applied.
    @Published private(set) var endpointSettingsNeedRepair = false
    private let workspacePanelStore: JSONFileStore<WorkspacePanelSettings>
    /// Specialist workspace panels the user switched on; core panels are always visible.
    @Published private(set) var workspacePanels = WorkspacePanelSettings()
    private let session: SurfaceSession
    private let configurationFile: ProtectedJSONFile<SurfaceConfiguration>
    let mcp: MCPController
    let provider: ProviderApplication
    let feedbackSettings: FeedbackSettingsController
    private var pendingTouchedControl: BCRControlID?
    private var uiPublishTask: Task<Void, Never>?
    let codex: CodexAgentController
    let library: ConfigurationLibrary
    let output: OutputController
    var source: DeviceSource { session.source }
    var engine: SurfaceEngine { session.engine }
    var mock: MockBCR2000 { session.mock }
    var connection: MIDIConnectionSnapshot { session.connection }
    var events: [MonitorEvent] { session.events }
    var droppedFeedbackCount: Int { session.droppedFeedbackCount }
    @Published private(set) var slots: [AgentSlot]
    @Published private(set) var notice: ConsoleNotice? {
        didSet { scheduleNoticeDismissal() }
    }

    private var noticeDismissTask: Task<Void, Never>?
    /// Informational notices without an action clear themselves; warnings, errors and
    /// anything the user can act on stay until dismissed.
    static let infoNoticeSeconds: Double = 6
    private var migratedHardwareMap: HardwareMap?
    private var migratedConfiguration = false
    private let hardwareFile: ProtectedJSONFile<HardwareMap>
    @Published private(set) var persistenceNotice: ConsoleNotice?
    @Published private(set) var visibleGroup = 1
    @Published private(set) var pendingHardwareConnection: HardwareConnectionPrompt?
    private var declinedHardwareConnectionRoute: MIDIConnectionSnapshot?
    private(set) var startupConfiguredGroup: Int?
    /// Only known after this app loaded the preset itself; the device never reports its preset number.
    private(set) var startupConfiguredPreset: Int? {
        didSet { if startupConfiguredPreset == nil { configuredDisplayContext = nil } }
    }

    private var configuredDisplayContext: (name: String, route: PresetRestoreRoute, locked: Bool)?
    /// The control whose value the panel's LED display shows, as the device does while a control moves.
    /// Not `@Published`: input bursts publish through the session's coalesced frame refresh.
    private(set) var display = BCRDisplayModel()
    /// Stepped by every transferred BCL line; observed only by the LED display.
    let displayMarquee = DisplayMarqueeState()
    /// `.showvalue` settings and preset name of the device's current preset, when last read.
    @Published private(set) var displayProfile: BCRDisplayProfile?
    private let displayProfileStore: JSONFileStore<BCRDisplayProfile>
    /// Proven numbers bound to exact working-copy definitions; survives restarts.
    private let presetNumberMemory: PresetNumberMemory
    private var displayRevertTask: Task<Void, Never>?
    private var startupProgram: MIDIStartupProgram?
    private var startupProgramError: (any Error)?
    private var connectionOfferTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    private var startupRoute: MIDIConnectionSnapshot?
    private(set) var observedHardwareGroup: Int?
    @Published private(set) var connectingHardware = false
    @Published private(set) var presetAlignment: PresetAlignmentState?
    /// Show Agent states on the two-state button LEDs by rhythm (blinking) instead of raw levels.
    @Published private(set) var blinksAgentLEDs: Bool
    private var agentSemantics: [AgentSlotID: IndicatorSemantic] = [:]
    private var blinkTask: Task<Void, Never>?
    private var blinkLevels: [AgentSlotID: UInt8] = [:]
    private let blinkPreference: JSONFileStore<Bool>
    private var presetDump: Data?
    private var presetPreviewRoute: MIDIConnectionSnapshot?
    private var presetPreviewMap: HardwareMap?
    private var presetPreviewConfiguration: SurfaceConfiguration?
    private var presetOperationRoute: MIDIConnectionSnapshot?
    private var presetOperationID: UUID?
    private var pendingPresetRestore: PendingPresetRestore?
    /// The last written alignment that can still be undone, independent of the window.
    @Published private(set) var presetRestorePoint: PresetRestorePoint?
    private let restorePointStore: JSONFileStore<PresetRestorePoint>
    private var alignmentTask: Task<Void, Never>?
    private let supportDirectory: URL
    @Published private(set) var hardwarePressedControls: Set<BCRControlID> = []
    private var pressTasks: [BCRControlID: Task<Void, Never>] = [:]
    private var pressStarted: [BCRControlID: Double] = [:]
    private var hardwareConnectionTask: Task<Void, Never>?
    private var midiInitializationTask: Task<Void, Never>?

    /// Suspends until the device work started so far has finished: MIDI start, the connection offer,
    /// a hardware connection, display/preset reads, alignment and the coalesced frame publish. Work
    /// those tasks start in turn is awaited too. Display hold, blink and notice timers are not work.
    /// Tests use this instead of sleeping for an assumed duration. Work that waits on something the
    /// caller has not released yet (a held device reply) would never finish, so it throws after `timeout`.
    func waitForBackgroundWork(timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var finished = Set<Task<Void, Never>>()
        var idleChecks = 0
        while idleChecks < 3 {
            let running = [midiInitializationTask, connectionOfferTask, hardwareConnectionTask, displayReadTask,
                           alignmentTask, uiPublishTask].compactMap { $0 }.filter { !finished.contains($0) }
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

    @Published private(set) var startingMIDI = false
    @Published var selectedControl: BCRControlID? = .pushEncoder(group: 1, 1)
    /// Select whichever control was last touched on the device.
    @Published var followsTouch = true

    private(set) var mockAgents: BCRMockAgentHost?

    init(stores: ConsoleStores = .standard, startsMIDI: Bool = true,
         mcpCredentials: (any MCPCredentialStore)? = nil, integrationTest: Bool = false,
         midiService: (any MIDIService)? = nil, outputTransport: (any OutputTransport)? = nil,
         initialPreset: ConfigurationPreset = .starter,
         codexFactory: (@MainActor () async throws -> CodexSessionCoordinator)? = nil,
         providerConfiguration: ProviderConfiguration = .init(),
         mockClock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
         automaticallyAdvancesMock: Bool = true)
    {
        provider = ProviderApplication(configuration: providerConfiguration, monotonic: mockClock)
        codex = CodexAgentController(
            directory: stores.configuration.fileURL.deletingLastPathComponent(),
            factory: codexFactory
        )
        library = ConfigurationLibrary(url: stores.configuration.fileURL.deletingLastPathComponent()
            .appending(path: "configuration-library.json"))
        slots = AgentStateMachine().slots

        supportDirectory = stores.configuration.fileURL.deletingLastPathComponent()
        displayProfileStore = JSONFileStore(fileURL: supportDirectory.appending(path: "display-profile.json"))
        displayProfile = try? displayProfileStore.load()
        presetNumberMemory = PresetNumberMemory(
            store: JSONFileStore(fileURL: supportDirectory.appending(path: "preset-number-evidence.json"))
        )
        restorePointStore = JSONFileStore(fileURL: supportDirectory.appending(path: "preset-alignment-restore.json"))
        presetRestorePoint = try? restorePointStore.load()
        blinkPreference = JSONFileStore(fileURL: supportDirectory.appending(path: "agent-led-blink.json"))
        blinksAgentLEDs = (try? blinkPreference.load()) ?? false
        let configurationFile = ProtectedJSONFile.configuration(stores.configuration, preset: initialPreset)
        self.configurationFile = configurationFile
        let hardwareFile = ProtectedJSONFile.hardware(stores.hardwareMap)
        self.hardwareFile = hardwareFile
        let mapRead = hardwareFile.load()
        let configRead = configurationFile.load()
        let loadedMap = mapRead.value
        let startupURL = stores.configuration.fileURL.deletingLastPathComponent()
            .appending(path: "hardware-startup.json")
        do { startupProgram = try JSONFileStore<MIDIStartupProgram>(fileURL: startupURL).load() }
        catch { startupProgramError = error }
        let configuration = configRead.value
        let messages = [mapRead.message, configRead.message].compactMap { $0 }
        if !messages.isEmpty {
            let failed = mapRead.failed || configRead.failed
            // A message without a failure is a version migration held in memory only.
            if !failed {
                migratedHardwareMap = mapRead.message == nil ? nil : loadedMap
                migratedConfiguration = configRead.message != nil
            }
            persistenceNotice = ConsoleNotice(level: failed ? .error : .info,
                                              text: messages.joined(separator: " "),
                                              action: failed ? nil : .saveMigration)
        }

        let endpointStore = JSONFileStore<MIDIEndpointSelection>(fileURL:
            stores.configuration.fileURL.deletingLastPathComponent().appending(path: "midi-endpoints.json"))
        self.endpointStore = endpointStore
        canConfigureMIDI = startsMIDI
        var endpointError: LocalizedMessage?
        var savedSelection = MIDIEndpointSelection()
        do {
            if let stored = try endpointStore.load() { try stored.validate(); savedSelection = stored }
        } catch { endpointError = "MIDI 端口设置读取失败：\(error: error)" }
        endpointSelection = savedSelection
        endpointSettingsNeedRepair = endpointError != nil
        let workspacePanelStore = JSONFileStore<WorkspacePanelSettings>(fileURL:
            stores.configuration.fileURL.deletingLastPathComponent().appending(path: "workspace-panels.json"))
        self.workspacePanelStore = workspacePanelStore
        var panelError: LocalizedMessage?
        do { if let stored = try workspacePanelStore.load() { workspacePanels = stored } }
        catch { panelError = "面板设置读取失败，专业面板保持隐藏：\(error: error)" }
        let midi = midiService ?? CoreMIDIService(selection: savedSelection)
        self.midi = midi
        session = SurfaceSession(
            hardwareDevice: midi, hardwareMap: loadedMap, configuration: configuration,
            pluginBindings: AgentBindingTranslation.bindings,
            requiresHardwareConfirmation: true,
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
        do { try ProviderMCPModule.install(on: mcp.service, application: provider) }
        catch { preconditionFailure("Invalid built-in provider module registration") }
        provider.start()
        midi.observeTransferLines { [weak self] direction in self?.displayMarquee.step(direction) }
        mcp.service.onReadAgents = { [weak self] in
            guard let self else { throw MCPToolFailure(L10n.text("Agent 服务不可用")) }
            return .object(["backend": .string(self.codex.backend.rawValue), "slots": try .encoded(self.slots)])
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
        session.onChange = { [weak self] in
            guard let self else { return }
            self.validateConnectionWork()
            guard self.uiPublishTask == nil else { return }
            self.uiPublishTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self else { return }
                if self.followsTouch, let control = self.pendingTouchedControl {
                    if self.selectedControl != control { self.selectedControl = control }
                    if (control.section == .pushEncoder || control.section == .pushEncoderButton),
                       self.visibleGroup != control.row
                    {
                        self.selectGroup(control.row)
                    }
                }
                self.pendingTouchedControl = nil
                self.objectWillChange.send()
                self.uiPublishTask = nil
            }
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
            mockAgents = host
            if codex.backend == .mock { slots = try host.slots }
            host.onError = { [weak self] in self?.report($0) }
            host.onUpdate = { [weak self] slots, feedback in
                guard let self, self.codex.backend == .mock else { return }
                let previous = Dictionary(uniqueKeysWithValues: self.slots.map { ($0.id, $0.state) })
                self.slots = slots
                for slot in slots where previous[slot.id] != slot.state {
                    if let value = feedback[slot.id] { self.showAgentState(slot, level: value) }
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
            do { try saveRestorePoint(point) } catch { report(error) }
        }
        guard startsMIDI else { return }
        midi.selectEndpoints(savedSelection)
        startMIDIWithoutBlockingWindow()
    }

    private func startMIDIWithoutBlockingWindow() {
        guard midiInitializationTask == nil else { return }
        startingMIDI = true
        let progress = ConsoleNotice(level: .info, message: "正在启动 MIDI 服务；界面可继续使用，请等待设备就绪。")
        if notice == nil { notice = progress }
        midiInitializationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startingMIDI = false; self.midiInitializationTask = nil }
            do {
                try await self.midi.startWhenReady()
                if self.notice == progress { self.notice = nil }
                if self.connection.isConnected { self.offerHardwareConnection() }
            } catch { self.notice = ConsoleNotice(level: .error, message: "CoreMIDI 启动失败：\(error: error)") }
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

    // MARK: Workspace panels

    /// Shows or hides a specialist panel and remembers the choice. Returns false when it was not saved.
    @discardableResult
    func setWorkspacePanel(_ panel: WorkspaceTab, enabled: Bool) -> Bool {
        do {
            var updated = workspacePanels
            try updated.set(panel, enabled: enabled)
            try workspacePanelStore.save(updated)
            workspacePanels = updated
            return true
        } catch {
            notice = ConsoleNotice(level: .error, message: "面板设置保存失败：\(error: error)")
            return false
        }
    }

    // MARK: Device source

    func applyEndpointSelection(_ selection: MIDIEndpointSelection) {
        guard canConfigureMIDI else {
            notice = ConsoleNotice(level: .warning, message: "隔离测试未启用实体 MIDI")
            return
        }
        do { try commitEndpointSelection(selection) } catch { report(error) }
    }

    /// Shared by the settings sheet and the MCP tool; failures stay with the caller.
    private func commitEndpointSelection(_ selection: MIDIEndpointSelection) throws {
        try selection.validate()
        try endpointStore.save(selection)
        endpointSettingsNeedRepair = false
        if output.settings.enabled { output.stop(failure: L10n.text("MIDI 端口已改变，请重新确认使能")) }
        endpointSelection = selection
        if isLearning { session.stopLearning() }
        midi.selectEndpoints(selection)
        startMIDIWithoutBlockingWindow()
        notice = ConsoleNotice(level: .info, message: "MIDI 端口设置已保存；端口缺失时不会自动替换手动选择")
    }

    private var presetSourceSwitchBlocked: Bool {
        presetAlignment?.phase.isBusy == true || pendingPresetRestore != nil || presetOperationID != nil
    }

    func selectSource(_ newSource: DeviceSource) {
        guard !presetSourceSwitchBlocked else {
            notice = ConsoleNotice(level: .warning, message: "预设操作尚未结束，暂不能切换设备来源。")
            return
        }
        connectionOfferTask?.cancel(); connectionOfferTask = nil
        pendingHardwareConnection = nil; declinedHardwareConnectionRoute = nil
        startupConfiguredGroup = nil; startupConfiguredPreset = nil
        presetNumberEvidence = nil
        latestDisplayDump = nil; pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil
        invalidateDisplayNumber()
        clearDisplayedValue()
        clearHardwarePresses()
        hardwareConnectionTask?.cancel()
        hardwareConnectionTask = nil
        startupTaskID = nil; startupRoute = nil
        connectingHardware = false
        observedHardwareGroup = nil
        session.selectSource(newSource)
    }

    /// Text of the 4-digit LED display, as the device would show it right now.
    var displayContent: BCRDisplayModel.Content {
        display.content(at: ProcessInfo.processInfo.systemUptime)
    }

    var displayText: String { BCRDisplayModel.text(for: displayContent) }

    /// True while a BCL dump or write runs; the device's display animates meanwhile.
    var displayBusy: Bool { display.transfers > 0 }
    var displayTransferOperation: BCRDisplayModel.TransferOperation { display.transferOperation }

    /// Runs one BCL transfer with the panel display animating like the device's.
    private func withDisplayTransfer<T>(_ operation: BCRDisplayModel.TransferOperation = .read,
                                        _ body: @MainActor () async throws -> T) async rethrows -> T
    {
        let transfer = display.beginTransfer(operation); objectWillChange.send()
        defer { display.endTransfer(transfer); objectWillChange.send() }
        return try await body()
    }

    /// Whether the device's preset locks PRESET and the function keys (they then act as plain,
    /// unassigned buttons). Nil when the preset has not been read or in mock mode.
    var deviceKeysLocked: Bool? { source == .hardware ? displayProfile?.locked : nil }

    /// Lit briefly after any message arrives from the device, like its MIDI IN activity LED.
    private(set) var deviceActivity = false
    private var activityTask: Task<Void, Never>?

    /// Turning on rides the session's coalesced frame refresh (input bursts must publish once per
    /// frame); only turning off publishes on its own, after the burst has ended.
    private func noteDeviceActivity() {
        activityTask?.cancel()
        deviceActivity = true
        activityTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            self?.objectWillChange.send()
            self?.deviceActivity = false
        }
    }

    /// The device's preset name, when it has been read; shown beside the 4-digit display.
    var displayPresetName: String? { source == .hardware ? displayProfile?.name : nil }

    private func showDeviceInput(_ control: BCRControlID, rawValue: UInt16, pressed: Bool?) {
        // The mock's preset shows every value; the device follows its own `.showvalue` settings.
        let shows = source == .mock || (displayProfile?.showsValue(control) ?? true)
        let now = ProcessInfo.processInfo.systemUptime
        if control.isContinuous {
            display.encoderMoved(rawValue: Int(rawValue), showsValue: shows, at: now)
        } else {
            display.buttonChanged(pressed: pressed, rawValue: Int(rawValue), showsValue: shows, at: now)
        }
        guard shows else { return }
        displayRevertTask?.cancel()
        displayRevertTask = Task { @MainActor [weak self] in
            // Values and button states are held for different times; wait for whichever is shown.
            let remaining = (self?.display.transient?.until ?? now) - now
            do { try await Task.sleep(for: .seconds(max(0, remaining))) } catch { return }
            self?.objectWillChange.send()
            self?.displayRevertTask = nil
        }
    }

    private func clearDisplayedValue() {
        displayRevertTask?.cancel(); displayRevertTask = nil
        if display.transient != nil { objectWillChange.send(); display.clearTransient() }
    }

    private func setDisplayPreset(_ preset: Int?) {
        display.setPreset(preset)
        objectWillChange.send()
    }

    private var displayReadTask: Task<Void, Never>?
    private var displayReadID: UUID?
    private var presetNumberEvidence: PresetNumberEvidence?
    private var latestDisplayDump: (route: PresetRestoreRoute, dump: Data)?
    @Published private(set) var pendingPresetNumberConfirmation: PresetNumberConfirmation?
    @Published private(set) var selectedPresetNumber: Int?
    private var verifiedDisplayNames: (route: MIDIConnectionSnapshot, names: BCRPresetNames)?

    /// Read-only, on entering hardware mode. The 33 preset names take under a second and usually
    /// give the number. Full dumps take 12–15 s each on firmware 1.10 (the device display animates
    /// meanwhile). ShowValue settings can be cached by name; resolving same-named candidates
    /// requires fresh dumps on each connection.
    /// A number proven on this route can follow an approved edit only while locked.
    private func verifiedConfiguredNumber(_ names: BCRPresetNames, route: MIDIConnectionSnapshot,
                                          locked: Bool = false) -> Int?
    {
        guard let number = startupConfiguredPreset, let context = configuredDisplayContext,
              context.route.matches(route), names.temporaryName == context.name,
              (names.candidates == [number] || (context.locked && locked)),
              names.memory.indices.contains(number - 1),
              names.memory[number - 1].trimmingCharacters(in: .whitespaces) == context.name else { return nil }
        return number
    }

    private func acceptDisplayNames(_ names: BCRPresetNames, route: MIDIConnectionSnapshot) {
        verifiedDisplayNames = (route, names)
        let candidates = names.candidates
        let configured = verifiedConfiguredNumber(names, route: route)
        if let context = configuredDisplayContext,
           !context.route.matches(route) || context.name != names.temporaryName ||
           !names.candidates.contains(startupConfiguredPreset ?? 0) ||
           (candidates.count > 1 && !context.locked) { startupConfiguredPreset = nil }
        if let evidence = presetNumberEvidence, !evidence.matches(names, on: route) { presetNumberEvidence = nil }
        let carried = presetNumberEvidence.flatMap { $0.locked ? $0.number : nil }
        let number = carried ?? configured ?? names.presetNumber
        setDisplayPreset(number)
        if displayProfile?.name == names.temporaryName {
            displayProfile?.resolvedPreset = number
            displayProfile?.resolvedCandidates = candidates
            if let profile = displayProfile {
                do { try displayProfileStore.save(profile) } catch { report(error) }
            }
        } else {
            displayProfile?.resolvedPreset = nil
            displayProfile?.resolvedCandidates = nil
        }
    }

    private func invalidateDisplayNumber() {
        verifiedDisplayNames = nil
        setDisplayPreset(nil)
    }

    private func refreshDisplayFromDevice() {
        guard canConfigureMIDI, midi.supportsStartupConfiguration, source == .hardware, connection.isConnected,
              presetAlignment?.phase.isBusy != true, pendingPresetRestore == nil else { return }
        let previous = displayReadTask
        previous?.cancel()
        let route = connection, id = UUID()
        displayReadID = id
        displayReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.displayReadID == id { self.displayReadTask = nil; self.displayReadID = nil } }
            await previous?.value
            var freshNames: BCRPresetNames?
            do {
                let names = try await self.presetNames(on: route)
                freshNames = names
                let needsNumber = self.display.preset == nil && names.candidates.count > 1
                let temporary = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                self.updateDisplayProfile(from: temporary)
                self.syncRingModes(from: temporary, route: route)
                if needsNumber {
                    try await self.resolveDisplayNumber(temporary: temporary, names: names, route: route)
                }
            } catch {
                guard self.displayReadID == id, !Task.isCancelled,
                      self.source == .hardware, self.connection.hasSameRoute(as: route), !self.isLearning
                else { return }
                if let number = freshNames?.presetNumber {
                    self.setDisplayPreset(number)
                    self.notice = ConsoleNotice(level: .warning,
                                                message: "未能读取设备显示设置或同步灯环：\(error: error)")
                } else {
                    self.invalidateDisplayNumber()
                    if !(error is CancellationError) {
                        self.notice = ConsoleNotice(level: .warning,
                                                    message: "未能核对预设编号，显示未知：\(error: error)")
                    }
                }
            }
        }
    }

    private func rememberPresetNumber(_ number: Int?, dump: Data, names: BCRPresetNames,
                                      route: MIDIConnectionSnapshot, originalDefinition: [String]? = nil,
                                      uniquenessProven: Bool = false) throws
    {
        let evidence = try PresetNumberEvidence(number: number, dump: dump, names: names, route: route,
                                                originalDefinition: originalDefinition,
                                                uniquenessProven: uniquenessProven)
        guard number == nil || evidence != nil else {
            throw PresetOperationError("编号证据与当前预设不一致，请重新核对。")
        }
        presetNumberEvidence = evidence
        // Persist the provenance too: session-only confirmations must not become restart proofs.
        if let evidence {
            do { try presetNumberMemory.remember(evidence) } catch { report(error) }
        }
        setDisplayPreset(number)
        displayProfile?.resolvedPreset = number
        displayProfile?.resolvedCandidates = names.candidates
        if let profile = displayProfile { try displayProfileStore.save(profile) }
    }

    private func resolveDisplayNumber(temporary: Data, names: BCRPresetNames,
                                      route: MIDIConnectionSnapshot) async throws
    {
        try requirePresetRoute(route)
        if let evidence = presetNumberEvidence, try evidence.matches(temporary, names: names, on: route) {
            try rememberPresetNumber(evidence.number, dump: temporary, names: names, route: route,
                                     originalDefinition: evidence.originalDefinition,
                                     uniquenessProven: evidence.uniquenessProven)
            return
        }
        let profile = try BCRDisplayProfile.read(fromPresetDump: temporary)
        // A number proven earlier (also before a restart) for exactly this definition on this route.
        let remembered = try presetNumberMemory.number(for: temporary, names: names, route: route)
        if let number = verifiedConfiguredNumber(names, route: route, locked: profile.locked == true)
            ?? names.presetNumber ?? remembered
        {
            try rememberPresetNumber(number, dump: temporary, names: names, route: route,
                                     uniquenessProven: remembered == number)
            return
        }
        presetNumberEvidence = nil
        let candidates = names.candidates
        // A locked copy without proof is usually an aligned (edited) copy that can never match a
        // stored slot; two more full dumps (~24 s of device busy time) on every connection would be
        // futile. Such copies use the recorded proof above or the explicit screen confirmation.
        guard profile.locked != true, candidates.count > 1, candidates.count <= 4 else { return }
        var dumps: [Int: Data] = [:]
        for number in candidates {
            try requirePresetRoute(route)
            dumps[number] = try await withDisplayTransfer { try await self.midi.readMemoryPreset(number) }
        }
        let latest = try await presetNames(on: route)
        guard latest.temporaryName == names.temporaryName, latest.candidates == candidates else { return }
        let number = try BCRPresetNames.resolve(temporary: temporary, candidates: dumps)
        try rememberPresetNumber(number, dump: temporary, names: latest, route: route,
                                 uniquenessProven: number != nil)
    }

    /// Failure to identify the LED number must not block a validated preset operation.
    private func tryResolveDisplayNumber(temporary: Data, names: BCRPresetNames,
                                         route: MIDIConnectionSnapshot) async throws
    {
        do { try await resolveDisplayNumber(temporary: temporary, names: names, route: route) }
        catch {
            try requirePresetRoute(route)
            presetNumberEvidence = nil
            invalidateDisplayNumber()
            notice = ConsoleNotice(level: .warning,
                                   message: "未能核对预设编号，显示未知：\(error: error)")
        }
    }

    private func updateDisplayProfile(from dump: Data) {
        do {
            var profile = try BCRDisplayProfile.read(fromPresetDump: dump)
            latestDisplayDump = (PresetRestoreRoute(connection), dump)
            if let context = verifiedDisplayNames, connection.hasSameRoute(as: context.route),
               context.names.temporaryName == profile.name
            {
                let evidence = presetNumberEvidence
                if let evidence, try !evidence.matches(dump, names: context.names, on: context.route) {
                    presetNumberEvidence = nil
                }
                profile.resolvedPreset = presetNumberEvidence?.number
                    ?? verifiedConfiguredNumber(context.names, route: context.route, locked: profile.locked == true)
                    ?? context.names.presetNumber
                profile.resolvedCandidates = context.names.candidates
            } else { presetNumberEvidence = nil }
            displayProfile = profile
            setDisplayPreset(profile.resolvedPreset)
            // The profile is a disposable settings cache, never a source of number evidence.
            // Fresh device data must repair malformed JSON instead of reloading it here.
            try displayProfileStore.save(profile)
        } catch { report(error) }
    }

    /// The device's working copy can change without this app (a power cycle or preset recall
    /// reverts an alignment). After every fresh read-only dump, draw each learned encoder's ring
    /// with the mode the device is actually using, so the panel shows what the hardware shows.
    private func syncRingModes(from dump: Data, route: MIDIConnectionSnapshot) {
        guard source == .hardware, connection.hasSameRoute(as: route), !isLearning else { return }
        do {
            let (map, changed) = try BCRPresetAlignment.syncingRingModes(session.learnedHardwareMap, with: dump)
            guard !changed.isEmpty else { return }
            try installVerifiedMap(map)
            notice = ConsoleNotice(level: .info,
                                   message: "已按设备当前预设更新 \(changed.count) 个旋钮的灯环显示模式；未写入设备。")
        } catch { report(error) }
    }

    var canCheckDisplayPresetNumber: Bool {
        canConfigureMIDI && midi.supportsStartupConfiguration && source == .hardware && connection.isConnected
            && !presetSourceSwitchBlocked && !isLearning && !startingMIDI
    }

    /// Read-only, on explicit user intent. A changed temporary preset may have no stored
    /// content match, so the operator can confirm the number actually visible on the device.
    func requestPresetNumberConfirmation() {
        guard canCheckDisplayPresetNumber else { return }
        pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil
        let previous = displayReadTask
        previous?.cancel()
        let route = connection, id = UUID()
        displayReadID = id
        displayReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.displayReadID == id { self.displayReadID = nil; self.displayReadTask = nil } }
            await previous?.value
            do {
                let names = try await self.presetNames(on: route)
                let dump: Data
                if let recent = self.latestDisplayDump, recent.route.matches(route),
                   self.displayProfile?.locked == true,
                   (try BCRDisplayProfile.read(fromPresetDump: recent.dump).name) == names.temporaryName
                {
                    dump = recent.dump
                } else { dump = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() } }
                try self.requirePresetRoute(route)
                self.updateDisplayProfile(from: dump)
                guard !names.candidates.isEmpty else {
                    throw PresetOperationError("当前名称没有对应的存储预设，无法确认编号。")
                }
                self.pendingPresetNumberConfirmation = PresetNumberConfirmation(route: PresetRestoreRoute(route),
                                                                                dump: dump, names: names)
            } catch {
                guard self.displayReadID == id, !Task.isCancelled else { return }
                self.report(error)
            }
        }
    }

    func selectDisplayPresetNumber(_ id: UUID, number: Int) {
        guard let context = pendingPresetNumberConfirmation, context.id == id,
              context.route.matches(connection), context.names.candidates.contains(number) else { return }
        selectedPresetNumber = number
    }

    func confirmDisplayPresetNumber(_ id: UUID, number: Int) {
        guard let context = pendingPresetNumberConfirmation, context.id == id,
              canCheckDisplayPresetNumber, context.route.matches(connection), context.names.candidates.contains(number),
              latestDisplayDump?.dump == context.dump,
              verifiedDisplayNames?.names == context.names else { return }
        do {
            let matchingEvidence = try presetNumberEvidence.flatMap { evidence -> PresetNumberEvidence? in
                guard evidence.number == number,
                      try evidence.matches(context.dump, names: context.names, on: connection) else { return nil }
                return evidence
            }
            let inSessionProof = matchingEvidence?.uniquenessProven ?? false
            let recordedProof = try presetNumberMemory.number(for: context.dump, names: context.names,
                                                              route: connection) == number
            let uniquenessProven = inSessionProof || recordedProof
            try rememberPresetNumber(number, dump: context.dump, names: context.names, route: connection,
                                     originalDefinition: matchingEvidence?.originalDefinition,
                                     uniquenessProven: uniquenessProven)
            pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil
            notice = ConsoleNotice(level: .info, message: uniquenessProven
                ? "已确认预设编号 \(number)；已有内容唯一性证明，定义一致时可跨连接恢复，不写入设备。"
                : "已按实机屏幕确认预设编号 \(number)；未证明内容唯一性，仅本次连接有效，不写入设备。")
        } catch { report(error) }
    }

    func cancelPresetNumberConfirmation() { pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil }

    private func clearHardwarePresses() {
        for task in pressTasks.values { task.cancel() }
        pressTasks.removeAll(); pressStarted.removeAll()
        if !hardwarePressedControls.isEmpty { hardwarePressedControls.removeAll() }
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

    @discardableResult
    func updateParameter(_ definition: ParameterDefinition) -> ParameterDefinition? {
        do {
            notice = ConsoleNotice(
                level: .info,
                message: "参数“\(BuiltInNamePresentation.displayName(definition.name))”已更新。"
            )
            try session.updateParameter(definition)
            return configuration.parameter(definition.id)
        } catch {
            report(error)
            return nil
        }
    }

    func removeParameter(_ id: ParameterID) {
        session.removeParameter(id)
    }

    /// Replaces all parameters and assignments with a built-in preset; the hardware map is kept.
    func loadPreset(_ preset: ConfigurationPreset) {
        let hint: LocalizedMessage = preset == .robotArm && !workspacePanels.isEnabled(.arm)
            ? "可从工作区“面板”菜单启用机械臂预览。" : ""
        let loaded: LocalizedMessage = "已载入“\(preset.title)”。"
        notice = ConsoleNotice(level: .info, message: "\(loaded)\(hint)")
        do { try session.replaceConfiguration(preset.makeConfiguration()) }
        catch { report(error) }
    }

    // MARK: Assignments

    func setAssignment(_ assignment: ControlAssignment?, for control: BCRControlID) {
        do { try session.setAssignment(assignment, for: control) }
        catch { report(error) }
    }

    func setCycleValues(_ text: String, parameter: ParameterID, for control: BCRControlID) {
        let fields = text.replacingOccurrences(of: "，", with: ",").split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        let values = fields.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == fields.count
        else { report(ConfigurationFileError(reason: L10n.text("循环值必须是逗号分隔的数值"))); return }
        setAssignment(
            ControlAssignment(control: control, target: .cycleParameter(id: parameter, values: values)),
            for: control
        )
    }

    func bulkAssignmentPlan(section: BCRSection, row: Int, group: String) -> BulkAssignmentPlan? {
        do { return try BulkAssignmentPlan(configuration: configuration, section: section, row: row, group: group) }
        catch { report(error); return nil }
    }

    @discardableResult
    func applyBulkAssignment(_ plan: BulkAssignmentPlan) -> Bool {
        do {
            notice = ConsoleNotice(level: .info, message: "已批量分配 \(plan.changes.count) 个控件。")
            try session.applyBulkAssignment(plan)
            return session.lastConfigurationPersistenceError == nil
        } catch { report(error); return false }
    }

    // MARK: Hardware map / learning

    func beginLearning(at control: BCRControlID, format: MIDILearnFormat = .voice) {
        guard session.beginLearning(at: control, format: format) else {
            notice = ConsoleNotice(level: .warning, message: "Mock 设备的预设已知，学习只用于实体 BCR2000。")
            return
        }
        selectedControl = control
        notice = ConsoleNotice(
            level: .info,
            message: "学习中：请操作实体 \(control.shortName)。完成后会自动跳到本区下一个未学习控件，可连续扫过整排。"
        )
    }

    func parameterFractionDigits(_ id: ParameterID) -> Int {
        configuration.controls(targetingParameter: id).contains {
            configuration.assignment(for: $0)?.encoderMode != .absolute || engine.hardwareMap.midi(for: $0)?
                .kind == .nrpn
        } ? 3 : 0
    }

    func setMockNRPN(_ enabled: Bool, for control: BCRControlID) {
        do { try session.setMockNRPN(enabled, for: control) }
        catch { report(error) }
    }

    func stopLearning() {
        session.stopLearning()
        notice = ConsoleNotice(
            level: .info,
            message: "学习已停止，已学习 \(learnedCount) / \(BCRLayout.allControls.count) 个控件。"
        )
    }

    func unbind(_ control: BCRControlID) {
        guard source == .hardware else { return }
        session.unbind(control)
    }

    var canChangeHardwareButtonFunctions: Bool {
        canConfigureMIDI && source == .hardware && connection.isConnected && !isLearning
            && !connectingHardware && presetAlignment?.phase.isBusy != true
    }

    /// Called only after the inspector confirms the captured binding. No device writes or resync.
    func setHardwareButtonFunctions(_ entry: HardwareMapEntry, enabled: Bool) {
        guard canChangeHardwareButtonFunctions, !entry.control.isContinuous else {
            notice = ConsoleNotice(level: .warning, message: "当前无法更改按键功能，请结束学习或设备操作后重试。")
            return
        }
        var map = session.learnedHardwareMap
        guard map.entries.first(where: { $0.control == entry.control }) == entry else {
            notice = ConsoleNotice(level: .warning, message: "按键绑定已改变，请重新确认。")
            return
        }
        do {
            try map.bind(entry.control, to: entry.midi, ringMode: entry.ringMode,
                         visualizationOnly: !enabled, pressMode: entry.pressMode)
            try session.installHardwareMap(map)
            // installHardwareMap reports persistence errors through the existing session event path.
        } catch { report(error) }
    }

    func resetHardwareMap() {
        guard source == .hardware else { return }
        notice = ConsoleNotice(level: .info, message: "实体映射已清空，请重新学习。")
        session.resetHardwareMap()
    }

    // MARK: Misc

    func clearMonitor() {
        session.clearMonitor()
    }

    func clearNotice() {
        notice = nil
    }

    private func scheduleNoticeDismissal() {
        noticeDismissTask?.cancel(); noticeDismissTask = nil
        guard let current = notice, current.level == .info, current.action == nil else { return }
        if startingMIDI, current == ConsoleNotice(level: .info,
                                                  message: "正在启动 MIDI 服务；界面可继续使用，请等待设备就绪。") { return }
        noticeDismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(Self.infoNoticeSeconds)) } catch { return }
            guard let self, self.notice == current else { return }
            self.notice = nil
        }
    }

    /// Writes the migrated map and configuration back. `ProtectedJSONFile.save` backs up the old
    /// version byte-for-byte first, so nothing is lost and the notice does not come back.
    private func saveMigration() {
        do {
            if let map = migratedHardwareMap { try hardwareFile.save(map) }
            if migratedConfiguration { try configurationFile.save(configuration) }
            migratedHardwareMap = nil; migratedConfiguration = false
            persistenceNotice = nil
            notice = ConsoleNotice(level: .info, message: "已保存升级后的文件，原文件已备份在同一目录。")
        } catch {
            persistenceNotice = ConsoleNotice(level: .error,
                                              message: "保存升级失败：\(error: error)",
                                              action: .saveMigration)
        }
    }

    func clearPersistenceNotice() {
        persistenceNotice = nil
    }

    func performNoticeAction(_ action: ConsoleNotice.Action) {
        switch action {
        case .switchToHardware:
            requestSource(.hardware)
        case .saveMigration:
            saveMigration()
        case .retryConfigurationSave:
            session.retryConfigurationPersistence()
            if session.lastConfigurationPersistenceError == nil {
                notice = ConsoleNotice(level: .info, message: "配置已保存。")
            }
        }
    }

    // MARK: Configuration transfer

    func selectPage(_ id: String) throws { try session.selectPage(id) }
    func updatePrograms(_ candidate: SurfaceConfiguration) throws { try session.updatePrograms(candidate) }

    func readConfiguration(from url: URL) throws -> SurfaceConfiguration {
        try ConfigurationTransfer.decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    @discardableResult
    func installConfiguration(_ candidate: SurfaceConfiguration) -> Bool {
        do {
            let candidate = try candidate.migrated()
            // Commit the durable configuration before changing the live engine.
            try configurationFile.save(candidate)
            notice = ConsoleNotice(
                level: .info,
                message: "已导入“\(BuiltInNamePresentation.displayName(candidate.name))”；实体映射保留。"
            )
            try session.replaceConfiguration(candidate, persist: false)
            return true
        } catch { report(error); return false }
    }

    private func presentConfigurationPanel(_ panel: NSSavePanel) async -> NSApplication.ModalResponse? {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil
        }) else {
            notice = ConsoleNotice(level: .error, message: "无法打开配置面板：请先关闭其他对话框。")
            return nil
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    func chooseConfigurationImport() async -> SurfaceConfiguration? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("导入参数与功能分配")
        panel.prompt = L10n.text("导入")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let response = await presentConfigurationPanel(panel)
        guard response == .OK, let url = panel.url else { return nil }
        do { return try readConfiguration(from: url) }
        catch {
            notice = ConsoleNotice(level: .error, message: "配置导入失败：\(error: error)")
            return nil
        }
    }

    func exportConfiguration(to url: URL) throws {
        let data = try ConfigurationTransfer.encode(configuration)
        if url.standardizedFileURL == configurationFile.store.fileURL.standardizedFileURL {
            try configurationFile.save(configuration)
        } else {
            try JSONFileStore<SurfaceConfiguration>(fileURL: url).writeEncoded(data)
        }
    }

    func chooseConfigurationExport() async {
        let panel = NSSavePanel()
        panel.title = L10n.text("导出参数与功能分配")
        panel.prompt = L10n.text("导出")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "surface-configuration.json"
        panel.canCreateDirectories = true
        let response = await presentConfigurationPanel(panel)
        guard response == .OK, let url = panel.url else { return }
        do {
            try exportConfiguration(to: url)
            notice = ConsoleNotice(level: .info, message: "配置已导出，不含实体映射。")
        } catch {
            notice = ConsoleNotice(level: .error, message: "配置导出失败：\(error: error)")
        }
    }

    // MARK: Preset alignment

    var canAlignPreset: Bool {
        canConfigureMIDI && midi.supportsStartupConfiguration && source == .hardware && connection.isConnected
            && !isLearning && !connectingHardware && presetAlignment?.phase.isBusy != true
            && pendingPresetRestore == nil
    }

    private func beginPresetWork(route: MIDIConnectionSnapshot) -> UUID {
        alignmentTask?.cancel()
        let id = UUID()
        presetOperationID = id
        presetOperationRoute = route
        return id
    }

    private func finishPresetWork(_ id: UUID) {
        if presetOperationID == id {
            presetOperationRoute = nil; presetOperationID = nil; alignmentTask = nil
        }
    }

    private func requirePresetRoute(_ route: MIDIConnectionSnapshot) throws {
        try Task.checkCancellation()
        guard canConfigureMIDI, midi.supportsStartupConfiguration, source == .hardware,
              connection.isConnected, connection.hasSameRoute(as: route), !isLearning
        else {
            throw PresetOperationError("设备连接或操作状态已改变，已停止预设操作。")
        }
    }

    private func presetNames(on route: MIDIConnectionSnapshot) async throws -> BCRPresetNames {
        try requirePresetRoute(route)
        invalidateDisplayNumber()
        let names = try await withDisplayTransfer { try await self.midi.readPresetNames() }
        try requirePresetRoute(route)
        acceptDisplayNames(names, route: route)
        return names
    }

    /// Reads the current temporary preset and prepares a preview. No device writes.
    func beginPresetAlignment(options: BCRPresetAlignment.Options = .init()) {
        guard canAlignPreset else {
            notice = ConsoleNotice(level: .warning, message: "请先在实体模式下连接 BCR2000，并停止学习。")
            return
        }
        let previousDisplayTask = displayReadTask
        previousDisplayTask?.cancel()
        presetAlignment = PresetAlignmentState(phase: .reading, options: options)
        presetDump = nil; presetPreviewRoute = nil
        let route = connection, id = beginPresetWork(route: connection)
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishPresetWork(id) }
            await previousDisplayTask?.value
            do {
                do { _ = try await self.presetNames(on: route) }
                catch {
                    try self.requirePresetRoute(route)
                    self.notice = ConsoleNotice(level: .warning,
                                                message: "未能核对预设编号，显示未知：\(error: error)")
                }
                let dump = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                self.presetDump = dump; self.presetPreviewRoute = route
                self.updateDisplayProfile(from: dump)
                self.syncRingModes(from: dump, route: route)
                if let context = self.verifiedDisplayNames {
                    try await self.tryResolveDisplayNumber(temporary: dump, names: context.names, route: route)
                }
                self.presetAlignment?.backup = try self.saveBackup(dump)
                self.presetAlignment?.phase = .preview
                self.recomputeAlignment()
            } catch {
                guard self.presetOperationID == id else { return }
                self.presetAlignment?.phase = .failed("读取设备预设失败：\(error: error)")
            }
        }
    }

    func setAlignmentOptions(_ options: BCRPresetAlignment.Options) {
        guard presetAlignment?.phase == .preview else { return }
        presetAlignment?.options = options
        recomputeAlignment()
    }

    private func recomputeAlignment() {
        guard let dump = presetDump, var state = presetAlignment else { return }
        do {
            state.plan = try BCRPresetAlignment.prepare(dump: dump, hardwareMap: session.learnedHardwareMap,
                                                        configuration: configuration, options: state.options)
            presetPreviewMap = session.learnedHardwareMap
            presetPreviewConfiguration = configuration
            state.planError = nil
        } catch {
            state.plan = nil
            state.planError = "\(error: error)"
        }
        presetAlignment = state
    }

    private func installVerifiedMap(_ map: HardwareMap) throws {
        try session.installHardwareMap(map)
        guard try hardwareFile.store.load() == map else {
            throw PresetOperationError("硬件映射未能保存，恢复点已保留。")
        }
    }

    /// The immutable confirmed document is the readback contract; live configuration edits
    /// cannot change what was sent or make a correct device response falsely fail verification.
    func applyPresetAlignment() {
        guard var state = presetAlignment, state.phase == .preview, let plan = state.plan, !plan.isEmpty,
              canAlignPreset, let route = presetPreviewRoute, let before = presetDump, let backup = state.backup,
              presetPreviewMap == session.learnedHardwareMap, presetPreviewConfiguration == configuration
        else {
            notice = ConsoleNotice(level: .warning, message: "请重新读取并确认设备预设预览。")
            return
        }
        do { try requirePresetRoute(route) } catch { report(error); return }
        let device = before[before.startIndex + 4]
        let frames = plan.frames(device: device)
        let previousMap = session.learnedHardwareMap, previousPoint = presetRestorePoint
        var point = PresetRestorePoint(backupFile: backup.lastPathComponent, hardwareMap: previousMap,
                                       createdAt: .now, route: PresetRestoreRoute(route),
                                       expectedPreset: Data(frames.joined()),
                                       expectedHardwareMap: previousMap, acknowledgedLines: 0,
                                       history: PresetRestorePoint.history(retaining: previousPoint),
                                       backupDigest: PresetBackupStore.digest(before))
        do { try saveRestorePoint(point) } catch { report(error); return }
        state.phase = .reading
        presetAlignment = state
        let previousDisplayTask = displayReadTask
        previousDisplayTask?.cancel()
        let id = beginPresetWork(route: route)
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishPresetWork(id) }
            await previousDisplayTask?.value
            var acknowledged = 0
            do {
                try self.requirePresetRoute(route)
                let names = try await self.presetNames(on: route)
                guard names.temporaryName == (try BCRDisplayProfile.read(fromPresetDump: before).name) else {
                    throw PresetOperationError("预览后设备预设已改变，请重新读取。")
                }
                let current = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                guard try BCRPresetAlignment.deviceIdentifier(of: current) == device,
                      try BCRPresetAlignment.identityLines(of: current) == BCRPresetAlignment.identityLines(of: before)
                else {
                    throw PresetOperationError("预览后设备预设已改变，请重新读取。")
                }
                guard self.session.learnedHardwareMap == previousMap else {
                    throw PresetOperationError("写入期间硬件映射已改变，未覆盖后续学习结果。")
                }
                let carriedEvidence = try self.presetNumberEvidence.flatMap {
                    try $0.matches(current, names: names, on: route) ? $0 : nil
                }
                // A partial write may change the lock. Only verified completion can
                // install the carried proof for the new working copy.
                self.presetNumberEvidence = nil; self.startupConfiguredPreset = nil
                self.invalidateDisplayNumber()
                self.presetAlignment?.phase = .writing(done: 0, total: frames.count)
                try await self.withDisplayTransfer(.write) {
                    try await self.midi.sendPresetFrames(frames) { [weak self] done in
                        acknowledged = done
                        guard let self, self.presetOperationID == id else { return }
                        // Only positive acknowledgement is needed for crash recovery. Keep
                        // exact progress in memory and save the final count on completion/failure.
                        if (point.acknowledgedLines ?? 0) == 0 {
                            point.acknowledgedLines = done
                            do { try self.saveRestorePoint(point) }
                            catch { self.report(error); self.alignmentTask?.cancel() }
                        }
                        self.presetAlignment?.phase = .writing(done: done, total: frames.count)
                        if self.source != .hardware || !self.connection.hasSameRoute(as: route) || self.isLearning {
                            self.alignmentTask?.cancel()
                        }
                    }
                }
                try self.requirePresetRoute(route)
                self.presetAlignment?.phase = .verifying
                let readback = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                guard try BCRPresetAlignment.readbackMatches(readback, expected: plan.lines) else {
                    throw PresetOperationError("回读与写入内容不一致")
                }
                guard self.session.learnedHardwareMap == previousMap else {
                    throw PresetOperationError("写入期间硬件映射已改变，未覆盖后续学习结果。")
                }
                let finalNames = try await self.presetNames(on: route)
                guard finalNames.temporaryName == (try BCRDisplayProfile.read(fromPresetDump: readback).name),
                      self.session.learnedHardwareMap == previousMap
                else {
                    throw PresetOperationError("写入期间预设或映射已改变，未覆盖当前映射。")
                }
                if (try BCRDisplayProfile.read(fromPresetDump: readback).locked) == true,
                   finalNames.candidates == names.candidates
                {
                    try self.rememberPresetNumber(
                        carriedEvidence?.number,
                        dump: readback,
                        names: finalNames,
                        route: route,
                        originalDefinition: carriedEvidence?.originalDefinition,
                        uniquenessProven: carriedEvidence?.uniquenessProven ?? false
                    )
                } else { self.presetNumberEvidence = nil }
                self.updateDisplayProfile(from: readback)
                try self.installVerifiedMap(plan.hardwareMap)
                point.expectedPreset = readback; point.expectedHardwareMap = plan.hardwareMap
                point.acknowledgedLines = acknowledged
                try self.saveRestorePoint(point)
                self.session.synchronize()
                self.presetAlignment?.canRestore = true
                self.presetAlignment?.phase = .finished
                self.notice = ConsoleNotice(level: .info,
                                            message: "设备临时预设已对齐（\(plan.changes.count) 项）；未写入永久存储。")
            } catch {
                guard self.presetOperationID == id else { return }
                // With no acknowledgement there is no confirmed edit to undo. Keep the old level.
                if acknowledged == 0 {
                    do { try self.saveRestorePoint(previousPoint) } catch { self.report(error) }
                } else {
                    point.acknowledgedLines = acknowledged
                    // Never adopt an arbitrary unexpected readback as a trusted recovery context.
                    // Only the original or complete confirmed target document is trusted.
                    if self.source == .hardware, self.connection.hasSameRoute(as: route), !self.isLearning,
                       !Task.isCancelled,
                       let partial = try? await self.withDisplayTransfer(
                           .read,
                           { try await self.midi.readCurrentPreset() }
                       ),
                       (try? BCRPresetAlignment.deviceIdentifier(of: partial)) == device,
                       (try? BCRPresetAlignment.identityLines(of: partial)) ==
                       (try? BCRPresetAlignment.identityLines(of: before))
                    {
                        point.expectedPreset = before
                    }
                    do { try self.saveRestorePoint(point) } catch { self.report(error) }
                }
                let failure: LocalizedMessage = "写入设备预设失败：\(error: error)"
                let recovery: LocalizedMessage = " 永久存储未改动；备份已保留，部分写入可能无法自动恢复，可丢弃此恢复层。"
                self.presetAlignment?.phase = .failed("\(failure)\(recovery)")
                self.presetAlignment?.canRestore = self.canRestorePreset
            }
        }
    }

    private var restoreUnavailableMessage: LocalizedMessage? {
        guard let point = presetRestorePoint else { return "没有可用的恢复点。" }
        guard canConfigureMIDI, midi.supportsStartupConfiguration else { return "当前设备不支持预设读写。" }
        guard source == .hardware, connection.isConnected else { return "请先在实体模式下连接原设备。" }
        guard !isLearning, !connectingHardware else { return "请先结束学习或连接操作。" }
        guard presetAlignment?.phase.isBusy != true,
              pendingPresetRestore == nil else { return "请先结束当前预设操作。" }
        guard let savedRoute = point.route, point.expectedPreset != nil, point.expectedHardwareMap != nil,
              point.backupDigest != nil,
              (point.acknowledgedLines ?? 0) > 0
        else {
            return "恢复点缺少已验证的设备上下文；备份保留，但不能自动写入。"
        }
        guard savedRoute.matches(connection) else { return "当前设备路由与恢复点不同，禁止恢复。" }
        return nil
    }

    var restoreUnavailableReason: String? { restoreUnavailableMessage.map { L10n.text($0) } }

    var canRestorePreset: Bool { restoreUnavailableReason == nil }

    /// Preflight is read-only: match persistent endpoints, names, and the entire known current
    /// document before any write. A different same-named preset is rejected by its content.
    func restorePresetBeforeAlignment() {
        guard canRestorePreset, let point = presetRestorePoint else {
            notice = ConsoleNotice(level: .warning, message: restoreUnavailableMessage ?? "没有可用的恢复点。")
            return
        }
        let previousDisplayTask = displayReadTask
        previousDisplayTask?.cancel()
        let route = connection, id = beginPresetWork(route: connection)
        presetAlignment = PresetAlignmentState(phase: .reading)
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishPresetWork(id) }
            await previousDisplayTask?.value
            do {
                let dump = try self.restoreDump(point)
                let names = try await self.presetNames(on: route)
                let backupName = try BCRDisplayProfile.read(fromPresetDump: dump).name
                guard names.temporaryName == backupName else {
                    throw PresetOperationError("当前预设名称与恢复备份不同，禁止恢复。")
                }
                let current = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(route)
                guard try self.matchesRestoreContext(current, point: point, backup: dump) else {
                    throw PresetOperationError("当前预设已改变，不能自动恢复旧备份。")
                }
                let context = PendingPresetRestore(point: point, dump: dump, route: route,
                                                   currentMap: self.session.learnedHardwareMap)
                if context.currentMap != point.expectedHardwareMap {
                    self.pendingPresetRestore = context
                    self.presetAlignment?.phase = .restoreConfirmation
                    return
                }
                try await self.performPresetRestore(context)
            } catch {
                guard self.presetOperationID == id else { return }
                self.presetAlignment?.phase = .failed("恢复失败：\(error: error)")
            }
        }
    }

    func confirmPresetRestoreReplacingLearning() {
        guard let context = pendingPresetRestore else { return }
        pendingPresetRestore = nil
        let id = beginPresetWork(route: context.route)
        presetAlignment?.phase = .reading
        alignmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishPresetWork(id) }
            do {
                try self.requirePresetRoute(context.route)
                guard self.session.learnedHardwareMap == context.currentMap else {
                    throw PresetOperationError("确认期间映射再次改变，请重新检查恢复操作。")
                }
                let names = try await self.presetNames(on: context.route)
                guard names.temporaryName == (try BCRDisplayProfile.read(fromPresetDump: context.dump).name) else {
                    throw PresetOperationError("当前预设名称与恢复备份不同，禁止恢复。")
                }
                let current = try await self.withDisplayTransfer { try await self.midi.readCurrentPreset() }
                try self.requirePresetRoute(context.route)
                guard try self.matchesRestoreContext(current, point: context.point, backup: context.dump) else {
                    throw PresetOperationError("当前预设已改变，不能自动恢复旧备份。")
                }
                let archive = try PresetMapArchiveStore(directory: self.presetBackupDirectory).save(context.currentMap)
                self.notice = ConsoleNotice(level: .info, message: "替换前的映射备份：\(archive.path)")
                try await self.performPresetRestore(context, mapArchive: archive)
            } catch {
                guard self.presetOperationID == id else { return }
                self.presetAlignment?.phase = .failed("恢复失败：\(error: error)")
            }
        }
    }

    func cancelPresetRestore() {
        guard pendingPresetRestore != nil else { return }
        pendingPresetRestore = nil
        presetAlignment = nil
        notice = ConsoleNotice(level: .info, message: "已取消恢复，设备与映射未改动。")
    }

    private func restoreDump(_ point: PresetRestorePoint) throws -> Data {
        guard point.backupFile == URL(fileURLWithPath: point.backupFile).lastPathComponent else {
            throw PresetOperationError("恢复备份路径无效。")
        }
        let dump = try Data(contentsOf: presetBackupDirectory.appending(path: point.backupFile))
        guard point.backupDigest == PresetBackupStore.digest(dump) else {
            throw PresetOperationError("恢复备份内容已改变，禁止写入。")
        }
        _ = try BCRPresetAlignment.prepare(dump: dump, hardwareMap: HardwareMap(), configuration: .neutral(),
                                           options: .init(completeButtons: false, ringModes: false,
                                                          buttonBehavior: false, lockPreset: false))
        _ = try BCRPresetAlignment.canonicalLines(of: dump)
        return dump
    }

    private func matchesRestoreContext(_ current: Data, point: PresetRestorePoint, backup: Data) throws -> Bool {
        guard let expected = point.expectedPreset,
              try BCRPresetAlignment.deviceIdentifier(of: current) == BCRPresetAlignment.deviceIdentifier(of: backup)
        else { return false }
        let actual = try BCRPresetAlignment.identityLines(of: current)
        if actual == (try BCRPresetAlignment.identityLines(of: expected)) { return true }
        // A failed verification can leave the exact approved backup already on the device.
        // Retrying that known target is safe; arbitrary partial documents are never adopted.
        guard point.restoreAttempted == true else { return false }
        return actual == (try BCRPresetAlignment.identityLines(of: backup))
    }

    private func performPresetRestore(_ context: PendingPresetRestore, mapArchive: URL? = nil) async throws {
        try requirePresetRoute(context.route)
        guard session.learnedHardwareMap == context.currentMap, presetRestorePoint == context.point else {
            throw PresetOperationError("恢复上下文已改变，请重新确认。")
        }
        let carriedEvidence = try presetNumberEvidence.flatMap { evidence -> PresetNumberEvidence? in
            guard evidence.locked, let expected = context.point.expectedPreset,
                  let names = verifiedDisplayNames?.names,
                  try evidence.matches(expected, names: names, on: context.route) else { return nil }
            return evidence
        }
        presetNumberEvidence = nil; startupConfiguredPreset = nil
        invalidateDisplayNumber()
        var writingPoint = context.point
        writingPoint.restoreAttempted = true
        try saveRestorePoint(writingPoint)
        let frames = Array(context.dump).split(separator: 0xF7, omittingEmptySubsequences: true)
            .map { Array($0) + [0xF7] }
        presetAlignment?.phase = .restoring
        presetAlignment?.restoreProgress = (0, frames.count)
        try await withDisplayTransfer(.write) {
            try await self.midi.sendPresetFrames(frames) { [weak self] done in
                guard let self else { return }
                self.presetAlignment?.restoreProgress = (done, frames.count)
                if self.source != .hardware || !self.connection.hasSameRoute(as: context.route) || self.isLearning {
                    self.alignmentTask?.cancel()
                }
            }
        }
        try requirePresetRoute(context.route)
        presetAlignment?.phase = .verifying
        let readback = try await withDisplayTransfer { try await self.midi.readCurrentPreset() }
        try requirePresetRoute(context.route)
        guard try BCRPresetAlignment.canonicalLines(of: readback) == BCRPresetAlignment
            .canonicalLines(of: context.dump)
        else {
            throw PresetOperationError("恢复回读与备份内容不一致；恢复点已保留。")
        }
        guard session.learnedHardwareMap == context.currentMap else {
            throw PresetOperationError("写入期间硬件映射已改变，未覆盖后续学习结果。")
        }
        let finalNames = try await presetNames(on: context.route)
        guard finalNames.temporaryName == (try BCRDisplayProfile.read(fromPresetDump: readback).name),
              session.learnedHardwareMap == context.currentMap
        else {
            throw PresetOperationError("写入期间预设或映射已改变，未覆盖当前映射。")
        }
        let restoredLocked = try BCRDisplayProfile.read(fromPresetDump: readback).locked == true
        let restoredDefinition = try BCRPresetAlignment.identityLines(of: readback)
        if let evidence = carriedEvidence, evidence.matches(finalNames, on: context.route),
           restoredLocked || restoredDefinition == evidence.originalDefinition
        {
            try rememberPresetNumber(evidence.number, dump: readback, names: finalNames, route: context.route,
                                     originalDefinition: evidence.originalDefinition,
                                     uniquenessProven: evidence.uniquenessProven)
        } else if let proven = try presetNumberMemory.number(for: readback, names: finalNames, route: context.route) {
            // Evidence rebuilt after a restart lacks the original definition, but the restored document
            // itself may have a content-uniqueness proof on this route (from the preview before the
            // alignment). Only such proofs qualify; manual session confirmations never do.
            try rememberPresetNumber(proven, dump: readback, names: finalNames, route: context.route,
                                     uniquenessProven: true)
        }
        updateDisplayProfile(from: readback)
        try installVerifiedMap(context.point.hardwareMap)
        try saveRestorePoint(context.point.previous)
        session.synchronize()
        presetAlignment?.canRestore = canRestorePreset
        presetAlignment?.phase = .finished
        notice = ConsoleNotice(level: .info, message: mapArchive.map { archive -> LocalizedMessage in
            "已恢复预设；替换前的映射备份：\(archive.path)"
        } ?? "已回读确认并恢复设备临时预设和本机映射。")
    }

    private func saveRestorePoint(_ candidate: PresetRestorePoint?) throws {
        let point = candidate?.bounded()
        if let point { try restorePointStore.save(point) }
        else if FileManager.default.fileExists(atPath: restorePointStore.fileURL.path) {
            try FileManager.default.removeItem(at: restorePointStore.fileURL)
        }
        presetRestorePoint = point
    }

    var canDiscardPresetRestore: Bool {
        presetRestorePoint != nil && presetAlignment?.phase.isBusy != true && pendingPresetRestore == nil
    }

    /// The UI confirms the exact level first. Skipping never writes to the device or map;
    /// older levels still require their own full content preflight.
    func discardPresetRestore(_ confirmed: PresetRestorePoint) {
        guard canDiscardPresetRestore, presetRestorePoint == confirmed else { return }
        do {
            try saveRestorePoint(confirmed.previous)
            presetAlignment?.canRestore = canRestorePreset
            notice = ConsoleNotice(level: .info, message: "已丢弃当前恢复层；设备、映射和预设备份未改动。")
        } catch { report(error) }
    }

    func dismissPresetAlignment() {
        guard presetAlignment?.phase.isBusy != true else { return }
        alignmentTask?.cancel(); alignmentTask = nil
        presetOperationRoute = nil; presetOperationID = nil; pendingPresetRestore = nil
        presetAlignment = nil
    }

    private var presetBackupDirectory: URL {
        supportDirectory.appending(path: "Backups", directoryHint: .isDirectory)
    }

    var canRevealPresetBackups: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: presetBackupDirectory.path, isDirectory: &directory)
            && directory.boolValue
    }

    /// Finder navigation only; never loads a preset or changes the restore point.
    func revealPresetBackups(file: URL? = nil) {
        if let file {
            guard FileManager.default.fileExists(atPath: file.path) else {
                notice = ConsoleNotice(level: .warning, message: "备份文件已不存在。")
                return
            }
            guard !skipsFinderWhenOffscreen() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            guard canRevealPresetBackups else {
                notice = ConsoleNotice(level: .info, message: "尚无预设备份。")
                return
            }
            guard !skipsFinderWhenOffscreen() else { return }
            if !NSWorkspace.shared.open(presetBackupDirectory) {
                notice = ConsoleNotice(level: .error, message: "无法打开备份文件夹。")
            }
        }
    }

    /// Offscreen test runs must not open Finder windows on the user's desktop; say so instead.
    private func skipsFinderWhenOffscreen() -> Bool {
        guard OffscreenPresentation.isEnabled else { return false }
        notice = ConsoleNotice(level: .info, message: "离屏测试模式不打开访达。")
        return true
    }

    private func saveBackup(_ dump: Data) throws -> URL {
        try PresetBackupStore(directory: presetBackupDirectory)
            .save(dump, protecting: presetRestorePoint?.protectedFiles ?? [])
    }

    // MARK: Session presentation

    private var hardwareConnectionConfirmation: HardwareConnectionConfirmation {
        guard source == .mock, connection.isConnected else { return .none }
        // Include the existing stabilization delay so a just-refused MCP call can immediately be polled.
        if pendingHardwareConnection != nil || connectionOfferTask != nil { return .pending }
        return declinedHardwareConnectionRoute?.hasSameRoute(as: connection) == true ? .declined : .none
    }

    private func validateConnectionWork() {
        if source != .hardware || !connection.isConnected || isLearning { displayReadTask?.cancel() }
        if let route = presetOperationRoute,
           source != .hardware || !connection.hasSameRoute(as: route) || isLearning
        {
            alignmentTask?.cancel()
        }
        if let route = declinedHardwareConnectionRoute,
           !connection.isConnected || !connection.hasSameRoute(as: route)
        {
            declinedHardwareConnectionRoute = nil
        }
        if let prompt = pendingHardwareConnection,
           !connection.isConnected || !connection.hasSameRoute(as: prompt.route)
        {
            pendingHardwareConnection = nil
        }
        if let route = startupRoute, !connection.isConnected || !connection.hasSameRoute(as: route) {
            hardwareConnectionTask?.cancel()
        }
    }

    /// Whether entering hardware mode would send any feedback to the device.
    private var hardwareSwitchWrites: Bool {
        session.learnedHardwareMap.entries.contains { $0.visualizationOnly != true }
    }

    private var readableEncoders: Set<MIDIControlID> {
        Set(session.learnedHardwareMap.entries.filter { $0.control.isContinuous }.map(\.midi))
    }

    private func offerHardwareConnection() {
        guard canConfigureMIDI, source == .mock, connection.isConnected, hardwareSwitchWrites,
              !connectingHardware, !presetSourceSwitchBlocked else { return }
        connectionOfferTask?.cancel()
        declinedHardwareConnectionRoute = nil
        let route = connection
        notice = ConsoleNotice(level: .info, message: "检测到硬件，等待连接稳定…")
        connectionOfferTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            defer { self.connectionOfferTask = nil }
            guard self.source == .mock, self.connection.isConnected,
                  self.connection.hasSameRoute(as: route) else { return }
            guard self.hardwareSwitchWrites else { return }
            let program = self.midi.supportsStartupConfiguration ? self.startupProgram : nil
            self.pendingHardwareConnection = HardwareConnectionPrompt(
                route: self.connection, program: program,
                canRead: self.midi.supportsSnapshotReadback && !self.readableEncoders.isEmpty
            )
            self.notice = ConsoleNotice(level: self.startupProgramError == nil ? .info : .error,
                                        message: self.startupProgramError.map { error -> LocalizedMessage in
                                            "硬件初始化设置不可用：\(error: error)"
                                        } ?? "请选择如何连接硬件；确认前不会写入设备。")
        }
    }

    func requestSource(_ newSource: DeviceSource) {
        if newSource == .hardware, startingMIDI {
            notice = ConsoleNotice(level: .info, message: "正在启动 MIDI 服务；界面可继续使用，请等待设备就绪。")
            return
        }
        guard !presetSourceSwitchBlocked else {
            notice = ConsoleNotice(level: .warning, message: "预设操作尚未结束，暂不能切换设备来源。")
            return
        }
        guard newSource == .hardware, source == .mock else { selectSource(newSource); return }
        guard hardwareSwitchWrites else {
            // Nothing learned can receive feedback, so entering hardware mode (e.g. to learn) writes nothing.
            selectSource(.hardware); return
        }
        guard canConfigureMIDI, connection.isConnected else {
            notice = ConsoleNotice(level: .warning, message: "尚未找到 BCR2000 Port 1，连接后需确认同步方向。")
            return
        }
        offerHardwareConnection()
    }

    func declineHardwareConnection(_ id: UUID) {
        guard let prompt = pendingHardwareConnection, prompt.id == id else { return }
        declinedHardwareConnectionRoute = prompt.route
        pendingHardwareConnection = nil
        notice = ConsoleNotice(level: .info, message: "保持 Mock，未进行本次硬件同步。")
    }

    func connectHardware(_ id: UUID, mode: HardwareConnectionPrompt.Mode) {
        guard let prompt = pendingHardwareConnection, prompt.id == id,
              source == .mock, connection.isConnected, connection.hasSameRoute(as: prompt.route) else { return }
        switch mode {
        case .initialize: guard prompt.program != nil else { return }
        case .write: guard prompt.canWrite else { return }
        case .read: guard prompt.canRead else { return }
        }
        let usingSoftware = mode == .initialize
        declinedHardwareConnectionRoute = nil
        pendingHardwareConnection = nil
        let operation = UUID(), route = connection
        startupTaskID = operation; startupRoute = route
        connectingHardware = true
        let parameterRevision = session.parameterSnapshot().revision
        let configurationRevision = session.configurationRevision
        let previousDisplayTask = displayReadTask
        let previousAlignmentTask = alignmentTask
        previousDisplayTask?.cancel()
        if mode == .write, previousDisplayTask == nil, previousAlignmentTask == nil {
            startupTaskID = nil; startupRoute = nil; connectingHardware = false
            session.selectSource(.hardware)
            return
        }
        notice = ConsoleNotice(level: .info, message: previousDisplayTask != nil || previousAlignmentTask != nil
            ? "等待设备完成上一轮预设发送，请暂勿操作设备…"
            : usingSoftware ? "正在初始化预设和分组，请暂勿操作设备…"
            : "正在读取硬件当前值，请暂勿操作旋钮…")
        hardwareConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.startupTaskID == operation {
                    self.connectingHardware = false; self.hardwareConnectionTask = nil
                    self.startupTaskID = nil; self.startupRoute = nil
                }
            }
            await previousDisplayTask?.value
            await previousAlignmentTask?.value
            do {
                try Task.checkCancellation()
                guard self.startupTaskID == operation, self.source == .mock,
                      self.connection.hasSameRoute(as: route), self.connection.isConnected
                else {
                    throw MIDIStartupError.noReply
                }
                if mode == .write {
                    self.session.selectSource(.hardware)
                    return
                }
                self.notice = ConsoleNotice(level: .info, message: usingSoftware
                    ? "正在初始化预设和分组，请暂勿操作设备…"
                    : "正在读取硬件当前值，请暂勿操作旋钮…")
                if usingSoftware, let program = prompt.program {
                    try await self.withDisplayTransfer(.write) { try await self.midi.configureStartup(program) }
                    try Task.checkCancellation()
                    guard self.source == .mock, self.connection.isConnected,
                          self.connection.hasSameRoute(as: route) else { throw MIDIStartupError.noReply }
                    self.visibleGroup = 1; self.session.selectGroup(1)
                    self.session.selectSource(.hardware)
                    self.observedHardwareGroup = nil; self.startupConfiguredGroup = 1
                    if let line = program.presetSettings.first(where: { $0.hasPrefix(".name '") }) {
                        self.configuredDisplayContext = (String(line.dropFirst(7).dropLast())
                            .trimmingCharacters(in: .whitespaces), PresetRestoreRoute(route),
                            program.presetSettings.contains(".lock on"))
                    }
                    self.startupConfiguredPreset = program.preset
                    self.setDisplayPreset(program.preset)
                    self.notice = ConsoleNotice(
                        level: .info,
                        message: "预设 \(program.preset)、分组 1 已初始化；软件参数已同步到设备。"
                    )
                } else {
                    let expected = self.readableEncoders
                    let messages = try await self
                        .withDisplayTransfer { try await self.midi.readSnapshot(expected: expected) }
                    try Task.checkCancellation()
                    guard self.source == .mock, self.connection.isConnected, self.connection.hasSameRoute(as: route),
                          self.session.parameterSnapshot().revision == parameterRevision,
                          self.session.configurationRevision == configurationRevision
                    else { throw HardwareSnapshotError.invalid }
                    try self.session.adoptHardwareSnapshot(messages)
                    self.observedHardwareGroup = nil; self.startupConfiguredGroup = nil
                    self.startupConfiguredPreset = nil
                    self.notice = ConsoleNotice(level: .info, message: "已读取硬件当前值；分组尚未确认，转动一个顶部旋钮即可跟随。")
                }
            } catch is CancellationError {
                guard self.startupTaskID == operation else { return }
                if self.connection.isConnected == false {
                    self.notice = ConsoleNotice(level: .warning, message: "设备已断开，硬件同步已取消；重连后请重新确认。")
                }
            } catch {
                guard self.startupTaskID == operation else { return }
                let recovery: LocalizedMessage = usingSoftware
                    ? " 设备可能停在部分设置的临时预设；永久存储未改动，重新载入预设或重启设备即可恢复。" : ""
                let failure: LocalizedMessage = "硬件连接失败：\(error: error)"
                self.notice = ConsoleNotice(level: .error, message: "\(failure)\(recovery)")
            }
        }
    }

    private func handleSessionEvent(_ event: SurfaceSessionEvent) {
        switch event {
        case .pageChanged:
            if notice?.level != .error, let warning = configuration
                .pageNavigationWarning { notice = ConsoleNotice(level: .warning, text: warning) }
        case let .sourceChanged(source):
            // The session may leave hardware on its own (e.g. route loss); no held press survives that.
            clearHardwarePresses()
            if source == .hardware { refreshDisplayFromDevice() }
            else {
                displayReadTask?.cancel(); presetNumberEvidence = nil; startupConfiguredPreset = nil
                latestDisplayDump = nil; pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil
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
            observedHardwareGroup = nil
            startupConfiguredGroup = nil; startupConfiguredPreset = nil
            presetNumberEvidence = nil
            latestDisplayDump = nil; pendingPresetNumberConfirmation = nil; selectedPresetNumber = nil
            invalidateDisplayNumber()
            clearDisplayedValue()
            clearHardwarePresses()
            offerHardwareConnection()
            if connectionOfferTask != nil || connectingHardware { return }
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
            if source == .hardware, control.section == .pushEncoder || control.section == .pushEncoderButton {
                observedHardwareGroup = control.row
            }
            guard followsTouch else { return }
            pendingTouchedControl = control
        case let .deviceInput(control, rawValue, pressed):
            if source == .hardware { noteDeviceActivity() }
            showDeviceInput(control, rawValue: rawValue, pressed: pressed)
        case let .buttonActivity(control, pressed):
            guard source == .hardware else { return }
            pressTasks[control]?.cancel()
            pressTasks[control] = nil
            if pressed == false {
                guard hardwarePressedControls.contains(control) else { return }
                let remaining = max(0, 0.08 - (ProcessInfo.processInfo.systemUptime - (pressStarted[control] ?? 0)))
                pressStarted[control] = nil
                if remaining == 0 { hardwarePressedControls.remove(control); return }
                pressTasks[control] = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                    self?.hardwarePressedControls.remove(control)
                    self?.pressTasks[control] = nil
                }
                return
            }
            hardwarePressedControls.insert(control)
            if pressed == true {
                pressStarted[control] = ProcessInfo.processInfo.systemUptime
                return
            }
            pressTasks[control] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                self?.hardwarePressedControls.remove(control)
                self?.pressTasks[control] = nil
            }
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
            }
            notice = ConsoleNotice(level: .error, message: "\(prefix)：\(message)",
                                   action: operation == .configurationPersistence ? .retryConfigurationSave : nil)
        }
    }

    /// Publishes agent slots and writes a changed state to the slot's LEDs.
    func applyAgentSlots(_ newSlots: [AgentSlot], changed slotID: AgentSlotID) {
        let previous = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.state) })
        slots = newSlots
        for slot in newSlots where previous[slot.id] != slot.state {
            showAgentState(slot, level: slot.state.feedbackValue)
        }
    }

    func setBlinksAgentLEDs(_ enabled: Bool) {
        guard enabled != blinksAgentLEDs else { return }
        blinksAgentLEDs = enabled
        do { try blinkPreference.save(enabled) } catch { report(error) }
        for slot in slots { showAgentState(slot, level: slot.state.feedbackValue) }
    }

    /// Writes one slot's state to its LEDs: the level directly, or a steady/blinking on-off pattern.
    private func showAgentState(_ slot: AgentSlot, level: UInt8) {
        agentSemantics[slot.id] = slot.state.indicatorSemantic
        guard blinksAgentLEDs else {
            blinkLevels[slot.id] = nil
            session.setIndicatorFeedback(AgentBindingTranslation.indicator(for: slot.id), value: level)
            updateBlinkTimer()
            return
        }
        refreshBlink(slot.id, at: ProcessInfo.processInfo.systemUptime)
        updateBlinkTimer()
    }

    private func refreshBlink(_ id: AgentSlotID, at time: Double) {
        guard let semantic = agentSemantics[id] else { return }
        let level: UInt8 = BCRIndicatorBlink.pattern(for: semantic).isOn(at: time) ? 127 : 0
        guard blinkLevels[id] != level else { return }
        blinkLevels[id] = level
        session.setIndicatorFeedback(AgentBindingTranslation.indicator(for: id), value: level)
    }

    /// One shared timer only while some slot blinks; steady states send nothing periodic.
    private func updateBlinkTimer() {
        let blinking = blinksAgentLEDs && agentSemantics.values.contains { semantic in
            if case .blink = BCRIndicatorBlink.pattern(for: semantic) { return true }
            return false
        }
        guard blinking else { blinkTask?.cancel(); blinkTask = nil; return }
        guard blinkTask == nil else { return }
        blinkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                for id in self.agentSemantics.keys { self.refreshBlink(id, at: now) }
            }
        }
    }

    func showSurfaceApprovalNotice() {
        notice = ConsoleNotice(level: .info, message: "请在 Agent 页查看详情后批准或拒绝")
    }

    func report(_ error: Error) {
        notice = ConsoleNotice(level: .error, message: "\(error: error)")
    }
}
