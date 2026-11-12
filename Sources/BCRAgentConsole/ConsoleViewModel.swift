import AppKit
import BCRAgentCore
import BCRPluginHost
import BCRProviderApplication
import BCRProviderMCPAdapter
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
    }

    let level: Level
    let text: String
    var action: Action?
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
    @Published private(set) var notice: ConsoleNotice?
    @Published private(set) var persistenceNotice: ConsoleNotice?
    @Published private(set) var visibleGroup = 1
    @Published private(set) var pendingHardwareConnection: HardwareConnectionPrompt?
    private(set) var startupConfiguredGroup: Int?
    private var startupProgram: MIDIStartupProgram?
    private var startupProgramError: String?
    private var connectionOfferTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    private var startupRoute: MIDIConnectionSnapshot?
    private(set) var observedHardwareGroup: Int?
    @Published private(set) var connectingHardware = false
    @Published private(set) var hardwarePressedControls: Set<BCRControlID> = []
    private var pressTasks: [BCRControlID: Task<Void, Never>] = [:]
    private var pressStarted: [BCRControlID: Double] = [:]
    private var hardwareConnectionTask: Task<Void, Never>?
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

        let configurationFile = ProtectedJSONFile.configuration(stores.configuration, preset: initialPreset)
        self.configurationFile = configurationFile
        let hardwareFile = ProtectedJSONFile.hardware(stores.hardwareMap)
        let mapRead = hardwareFile.load()
        let configRead = configurationFile.load()
        let loadedMap = mapRead.value
        let startupURL = stores.configuration.fileURL.deletingLastPathComponent()
            .appending(path: "hardware-startup.json")
        do { startupProgram = try JSONFileStore<MIDIStartupProgram>(fileURL: startupURL).load() }
        catch { startupProgramError = error.localizedDescription }
        let configuration = configRead.value
        let messages = [mapRead.message, configRead.message].compactMap { $0 }
        if !messages.isEmpty {
            persistenceNotice = ConsoleNotice(level: mapRead.failed || configRead.failed ? .error : .info,
                                              text: messages.joined(separator: " "))
        }

        let endpointStore = JSONFileStore<MIDIEndpointSelection>(fileURL:
            stores.configuration.fileURL.deletingLastPathComponent().appending(path: "midi-endpoints.json"))
        self.endpointStore = endpointStore
        canConfigureMIDI = startsMIDI
        var endpointError: String?
        var savedSelection = MIDIEndpointSelection()
        do {
            if let stored = try endpointStore.load() { try stored.validate(); savedSelection = stored }
        } catch { endpointError = L10n.text("MIDI 端口设置读取失败：\(error.localizedDescription)") }
        endpointSelection = savedSelection
        let workspacePanelStore = JSONFileStore<WorkspacePanelSettings>(fileURL:
            stores.configuration.fileURL.deletingLastPathComponent().appending(path: "workspace-panels.json"))
        self.workspacePanelStore = workspacePanelStore
        var panelError: String?
        do { if let stored = try workspacePanelStore.load() { workspacePanels = stored } }
        catch { panelError = L10n.text("面板设置读取失败，专业面板保持隐藏：\(error.localizedDescription)") }
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
        mcp.service.onSelectSource = { [weak self] source in
            guard let self else { throw MCPToolFailure(L10n.text("设备切换服务不可用")) }
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
            notice = ConsoleNotice(level: .info, text: L10n.text("隔离集成测试：使用独立配置与内存凭据，不连接实体设备。"))
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
                    if let value = feedback[slot.id] {
                        self.session.setIndicatorFeedback(AgentBindingTranslation.indicator(for: slot.id), value: value)
                    }
                }
            }
            if automaticallyAdvancesMock { host.startDriving() }
        } catch { report(error) }
        do { try ProviderMCPModule.installShared(on: mcp.service, application: provider) }
        catch { report(error) }
        session.synchronize()
        Task { @MainActor [weak mcp] in await mcp?.restore() }
        Task { @MainActor [weak output] in output?.restore() }
        if let panelError { notice = ConsoleNotice(level: .error, text: panelError) }
        if let endpointError {
            notice = ConsoleNotice(level: .error, text: [panelError, endpointError].compactMap { $0 }
                .joined(separator: " "))
            return
        }
        guard startsMIDI else { return }
        midi.selectEndpoints(savedSelection)
        do {
            try midi.start()
            if connection.isConnected { offerHardwareConnection() }
        } catch { notice = ConsoleNotice(level: .error, text: L10n.text("CoreMIDI 启动失败：\(error.localizedDescription)"))
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
            notice = ConsoleNotice(level: .error, text: L10n.text("面板设置保存失败：\(error.localizedDescription)"))
            return false
        }
    }

    // MARK: Device source

    func applyEndpointSelection(_ selection: MIDIEndpointSelection) {
        guard canConfigureMIDI else {
            notice = ConsoleNotice(level: .warning, text: L10n.text("隔离测试未启用实体 MIDI"))
            return
        }
        do {
            try selection.validate()
            try endpointStore.save(selection)
            if output.settings.enabled { output.stop(failure: L10n.text("MIDI 端口已改变，请重新确认使能")) }
            endpointSelection = selection
            if isLearning { session.stopLearning() }
            midi.selectEndpoints(selection)
            try midi.start()
            notice = ConsoleNotice(level: .info, text: L10n.text("MIDI 端口设置已保存；端口缺失时不会自动替换手动选择"))
        } catch { report(error) }
    }

    func selectSource(_ newSource: DeviceSource) {
        connectionOfferTask?.cancel(); connectionOfferTask = nil
        pendingHardwareConnection = nil; startupConfiguredGroup = nil
        clearHardwarePresses()
        hardwareConnectionTask?.cancel()
        hardwareConnectionTask = nil
        startupTaskID = nil; startupRoute = nil
        connectingHardware = false
        observedHardwareGroup = nil
        session.selectSource(newSource)
    }

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
            notice = ConsoleNotice(level: .info, text: L10n.text("参数“\(definition.name)”已更新。"))
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
        let hint = preset == .robotArm && !workspacePanels.isEnabled(.arm)
            ? L10n.text("可从工作区“面板”菜单启用机械臂预览。") : ""
        notice = ConsoleNotice(level: .info, text: L10n.text("已载入“\(preset.title)”。") + hint)
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
            notice = ConsoleNotice(level: .info, text: L10n.text("已批量分配 \(plan.changes.count) 个控件。"))
            try session.applyBulkAssignment(plan)
            return session.lastConfigurationPersistenceError == nil
        } catch { report(error); return false }
    }

    // MARK: Hardware map / learning

    func beginLearning(at control: BCRControlID, format: MIDILearnFormat = .voice) {
        guard session.beginLearning(at: control, format: format) else {
            notice = ConsoleNotice(level: .warning, text: L10n.text("Mock 设备的预设已知，学习只用于实体 BCR2000。"))
            return
        }
        selectedControl = control
        notice = ConsoleNotice(
            level: .info,
            text: L10n.text("学习中：请操作实体 \(control.shortName)。完成后会自动跳到本区下一个未学习控件，可连续扫过整排。")
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
            text: L10n.text("学习已停止，已学习 \(learnedCount) / \(BCRLayout.allControls.count) 个控件。")
        )
    }

    func unbind(_ control: BCRControlID) {
        guard source == .hardware else { return }
        session.unbind(control)
    }

    func resetHardwareMap() {
        guard source == .hardware else { return }
        notice = ConsoleNotice(level: .info, text: L10n.text("实体映射已清空，请重新学习。"))
        session.resetHardwareMap()
    }

    // MARK: Misc

    func clearMonitor() {
        session.clearMonitor()
    }

    func clearNotice() {
        notice = nil
    }

    func clearPersistenceNotice() {
        persistenceNotice = nil
    }

    func performNoticeAction(_ action: ConsoleNotice.Action) {
        switch action {
        case .switchToHardware:
            requestSource(.hardware)
        case .retryConfigurationSave:
            session.retryConfigurationPersistence()
            if session.lastConfigurationPersistenceError == nil {
                notice = ConsoleNotice(level: .info, text: L10n.text("配置已保存。"))
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
            notice = ConsoleNotice(level: .info, text: L10n.text("已导入“\(candidate.name)”；实体映射保留。"))
            try session.replaceConfiguration(candidate, persist: false)
            return true
        } catch { report(error); return false }
    }

    private func presentConfigurationPanel(_ panel: NSSavePanel) async -> NSApplication.ModalResponse? {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil
        }) else {
            notice = ConsoleNotice(level: .error, text: L10n.text("无法打开配置面板：请先关闭其他对话框。"))
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
            notice = ConsoleNotice(level: .error, text: L10n.text("配置导入失败：\(error.localizedDescription)"))
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
            notice = ConsoleNotice(level: .info, text: L10n.text("配置已导出，不含实体映射。"))
        } catch {
            notice = ConsoleNotice(level: .error, text: L10n.text("配置导出失败：\(error.localizedDescription)"))
        }
    }

    // MARK: Session presentation

    private func validateConnectionWork() {
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
              !connectingHardware else { return }
        connectionOfferTask?.cancel()
        let route = connection
        notice = ConsoleNotice(level: .info, text: L10n.text("检测到硬件，等待连接稳定…"))
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
                                        text: self.startupProgramError.map { L10n.text("硬件初始化设置不可用：\($0)") }
                                            ?? L10n.text("请选择如何连接硬件；确认前不会写入设备。"))
        }
    }

    func requestSource(_ newSource: DeviceSource) {
        guard newSource == .hardware, source == .mock else { selectSource(newSource); return }
        guard hardwareSwitchWrites else {
            // Nothing learned can receive feedback, so entering hardware mode (e.g. to learn) writes nothing.
            selectSource(.hardware); return
        }
        guard canConfigureMIDI, connection.isConnected else {
            notice = ConsoleNotice(level: .warning, text: L10n.text("尚未找到 BCR2000 Port 1，连接后需确认同步方向。"))
            return
        }
        offerHardwareConnection()
    }

    func declineHardwareConnection(_ id: UUID) {
        guard pendingHardwareConnection?.id == id else { return }
        pendingHardwareConnection = nil
        notice = ConsoleNotice(level: .info, text: L10n.text("保持 Mock，未进行本次硬件同步。"))
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
        pendingHardwareConnection = nil
        let operation = UUID(), route = connection
        startupTaskID = operation; startupRoute = route
        connectingHardware = true
        let parameterRevision = session.parameterSnapshot().revision
        let configurationRevision = session.configurationRevision
        if mode == .write {
            startupTaskID = nil; startupRoute = nil; connectingHardware = false
            session.selectSource(.hardware)
            return
        }
        notice = ConsoleNotice(level: .info, text: usingSoftware ? L10n.text("正在初始化预设和分组，请暂勿操作设备…")
            : L10n.text("正在读取硬件当前值，请暂勿操作旋钮…"))
        hardwareConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.startupTaskID == operation {
                    self.connectingHardware = false; self.hardwareConnectionTask = nil
                    self.startupTaskID = nil; self.startupRoute = nil
                }
            }
            do {
                if usingSoftware, let program = prompt.program {
                    try await self.midi.configureStartup(program)
                    try Task.checkCancellation()
                    guard self.source == .mock, self.connection.isConnected,
                          self.connection.hasSameRoute(as: route) else { throw MIDIStartupError.noReply }
                    self.visibleGroup = 1; self.session.selectGroup(1)
                    self.session.selectSource(.hardware)
                    self.observedHardwareGroup = nil; self.startupConfiguredGroup = 1
                    self.notice = ConsoleNotice(
                        level: .info,
                        text: L10n.text("预设 \(program.preset)、分组 1 已初始化；软件参数已同步到设备。")
                    )
                } else {
                    let expected = self.readableEncoders
                    let messages = try await self.midi.readSnapshot(expected: expected)
                    try Task.checkCancellation()
                    guard self.source == .mock, self.connection.isConnected, self.connection.hasSameRoute(as: route),
                          self.session.parameterSnapshot().revision == parameterRevision,
                          self.session.configurationRevision == configurationRevision
                    else { throw HardwareSnapshotError.invalid }
                    try self.session.adoptHardwareSnapshot(messages)
                    self.observedHardwareGroup = nil; self.startupConfiguredGroup = nil
                    self.notice = ConsoleNotice(level: .info, text: L10n.text("已读取硬件当前值；分组尚未确认，转动一个顶部旋钮即可跟随。"))
                }
            } catch is CancellationError {
                if self.connection.isConnected == false {
                    self.notice = ConsoleNotice(level: .warning, text: L10n.text("设备已断开，硬件同步已取消；重连后请重新确认。"))
                }
            } catch {
                let recovery = usingSoftware
                    ? L10n.text(" 设备可能停在部分设置的临时预设；永久存储未改动，重新载入预设或重启设备即可恢复。") : ""
                self.notice = ConsoleNotice(level: .error,
                                            text: L10n.text("硬件连接失败：\(error.localizedDescription)") + recovery)
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
            switch source {
            case .mock:
                notice = ConsoleNotice(level: .info, text: L10n.text("已切换到 Mock 设备：在虚拟面板上拖动旋钮、按下按键即模拟实体操作。"))
            case .hardware:
                notice = connection.isConnected
                    ? ConsoleNotice(level: .info, text: L10n.text("已切换到实体 BCR2000，软件状态已整体回写。"))
                    : ConsoleNotice(level: .warning, text: L10n.text("已切换到实体模式，但尚未找到 BCR2000 Port 1。"))
            }
        case let .connected(snapshot):
            observedHardwareGroup = nil
            startupConfiguredGroup = nil
            clearHardwarePresses()
            offerHardwareConnection()
            if connectionOfferTask != nil || connectingHardware { return }
            if source == .hardware {
                notice = ConsoleNotice(
                    level: .info,
                    text: L10n.text("已连接 \(snapshot.connectedSource ?? "BCR2000")，软件状态已整体回写。")
                )
            } else {
                notice = ConsoleNotice(
                    level: .info,
                    text: L10n.text("检测到 \(snapshot.connectedSource ?? "BCR2000")。当前仍在 Mock 模式，实体输入只记录不执行。"),
                    action: .switchToHardware
                )
            }
        case let .touched(control):
            if source == .hardware, control.section == .pushEncoder || control.section == .pushEncoderButton {
                observedHardwareGroup = control.row
            }
            guard followsTouch else { return }
            pendingTouchedControl = control
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
            let previous = notice?.text ?? ""
            notice = ConsoleNotice(level: notice?.level ?? .info,
                                   text: previous + L10n.text(" 配置替换已停止 \(control.shortName) 的学习。"),
                                   action: notice?.action)
        case let .learned(control, midi, next):
            selectedControl = next ?? control
            notice = ConsoleNotice(level: .info, text: next.map {
                L10n.text("\(control.shortName) = \(midi)。下一个：请操作 \($0.shortName)。")
            } ?? L10n.text("\(control.shortName) = \(midi)。本区已全部学习，学习结束。"))
        case let .learnRejected(_, error):
            notice = ConsoleNotice(level: .warning, text: error.localizedDescription)
        case let .failed(operation, message):
            let prefix: String
            switch operation {
            case .feedback: prefix = L10n.text("反馈发送失败")
            case .hardwareMapPersistence: prefix = L10n.text("硬件映射保存失败")
            case .configurationPersistence: prefix = L10n.text("功能配置保存失败")
            }
            notice = ConsoleNotice(level: .error, text: "\(prefix)：\(message)",
                                   action: operation == .configurationPersistence ? .retryConfigurationSave : nil)
        }
    }

    /// Publishes agent slots and writes a changed state to the slot's LEDs.
    func applyAgentSlots(_ newSlots: [AgentSlot], changed slotID: AgentSlotID) {
        let previous = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.state) })
        slots = newSlots
        for slot in newSlots where previous[slot.id] != slot.state {
            session.setIndicatorFeedback(
                AgentBindingTranslation.indicator(for: slot.id),
                value: slot.state.feedbackValue
            )
        }
    }

    func showSurfaceApprovalNotice() {
        notice = ConsoleNotice(level: .info, text: L10n.text("请在 Agent 页查看详情后批准或拒绝"))
    }

    func report(_ error: Error) {
        notice = ConsoleNotice(level: .error, text: error.localizedDescription)
    }
}
