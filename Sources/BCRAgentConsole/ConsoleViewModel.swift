import AppKit
import BCRAgentCore
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
    @Published var selectedControl: BCRControlID? = .pushEncoder(group: 1, 1)
    /// Select whichever control was last touched on the device.
    @Published var followsTouch = true

    var agentMachine = AgentStateMachine()
    var mockTasks: [AgentSlotID: Task<Void, Never>] = [:]

    init(stores: ConsoleStores = .standard, startsMIDI: Bool = true,
         mcpCredentials: (any MCPCredentialStore)? = nil, integrationTest: Bool = false,
         midiService: (any MIDIService)? = nil, outputTransport: (any OutputTransport)? = nil,
         initialPreset: ConfigurationPreset = .starter,
         codexFactory: (@MainActor () async throws -> CodexSessionCoordinator)? = nil,
         providerConfiguration: ProviderConfiguration = .init())
    {
        provider = ProviderApplication(configuration: providerConfiguration)
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
        adapter: outputTransport ?? OutputTransportRouter())
        do { try ProviderMCPModule.install(on: mcp.service, application: provider) }
        catch { preconditionFailure("Invalid built-in provider module registration") }
        provider.start()
        mcp.service.onReadAgents = { [weak self] in
            guard let self else { throw MCPToolFailure(L10n.text("Agent 服务不可用")) }
            return .object(["backend": .string(self.codex.backend.rawValue), "slots": try .encoded(self.slots)])
        }
        mcp.service.onAgentAction = { [weak self] action, slot in
            guard let self else { throw MCPToolFailure(L10n.text("Agent 服务不可用")) }
            if action == "stop_all_agents" {
                self.mockTasks.values.forEach { $0.cancel() }
                self.mockTasks.removeAll()
                for slot in self.agentMachine.slots where slot.state.isActive { self.interrupt(slot.id) }
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
                self.start(slot)
            } else { self.interrupt(slot) }
        }
        mcp.service.onSelectSource = { [weak self] source in
            guard let self else { throw MCPToolFailure(L10n.text("设备切换服务不可用")) }
            if source == .hardware, !self.canConfigureMIDI { throw MCPToolFailure(L10n.text("隔离测试未启用实体 MIDI")) }
            self.selectSource(source)
        }
        codex.onStopMock = { [weak self] in
            guard let self else { return }
            self.mockTasks.values.forEach { $0.cancel() }
            self.mockTasks.removeAll()
            self.agentMachine = AgentStateMachine()
            for slot in self.agentMachine.slots { self.applyAgentSlots(self.agentMachine.slots, changed: slot.id) }
        }
        codex.onSlots = { [weak self] slots in
            guard let self else { return }
            for slot in slots { self.applyAgentSlots(slots, changed: slot.id) }
        }
        session.onChange = { [weak self] in
            guard let self, self.uiPublishTask == nil else { return }
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
        session.onTriggerAgent = { [weak self] in self?.performSurfaceAgentAction($0) }
        if integrationTest {
            notice = ConsoleNotice(level: .info, text: L10n.text("隔离集成测试：使用独立配置与内存凭据，不连接实体设备。"))
        }
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
        do { try midi.start() }
        catch { notice = ConsoleNotice(level: .error, text: L10n.text("CoreMIDI 启动失败：\(error.localizedDescription)")) }
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
            selectSource(.hardware)
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

    private func handleSessionEvent(_ event: SurfaceSessionEvent) {
        switch event {
        case .pageChanged:
            if notice?.level != .error, let warning = configuration
                .pageNavigationWarning { notice = ConsoleNotice(level: .warning, text: warning) }
        case let .sourceChanged(source):
            switch source {
            case .mock:
                notice = ConsoleNotice(level: .info, text: L10n.text("已切换到 Mock 设备：在虚拟面板上拖动旋钮、按下按键即模拟实体操作。"))
            case .hardware:
                notice = connection.isConnected
                    ? ConsoleNotice(level: .info, text: L10n.text("已切换到实体 BCR2000，软件状态已整体回写。"))
                    : ConsoleNotice(level: .warning, text: L10n.text("已切换到实体模式，但尚未找到 BCR2000 Port 1。"))
            }
        case let .connected(snapshot):
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
            guard followsTouch else { return }
            pendingTouchedControl = control
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
            session.setAgentFeedback(slot.id, value: slot.state.feedbackValue)
        }
    }

    func showSurfaceApprovalNotice() {
        notice = ConsoleNotice(level: .info, text: L10n.text("请在 Agent 页查看详情后批准或拒绝"))
    }

    func report(_ error: Error) {
        notice = ConsoleNotice(level: .error, text: error.localizedDescription)
    }
}
