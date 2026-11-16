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
import UniformTypeIdentifiers
import Combine
import Foundation

@MainActor
protocol ConsoleConnectionPresetPort: AnyObject {
    var displayReadTask: Task<Void, Never>? { get }
    var alignmentTask: Task<Void, Never>? { get }
    var presetSourceSwitchBlocked: Bool { get }
    func clearNumberContext()
    func invalidateDisplayNumber()
}

@MainActor
protocol ConsoleConnectionRecoveryPort: AnyObject {
    var restoreTask: Task<Void, Never>? { get }
}

@MainActor
final class ConsoleConnectionWork: ObservableObject, ConsoleDeviceOwner {
    let context: ConsoleDeviceContext
    private let endpointStore: JSONFileStore<MIDIEndpointSelection>
    private let output: OutputController
    private let preset: any ConsoleConnectionPresetPort
    private let recovery: any ConsoleConnectionRecoveryPort
    @Published private(set) var endpointSelection: MIDIEndpointSelection
    @Published private(set) var endpointSettingsNeedRepair: Bool
    let endpointError: LocalizedMessage?
    @Published private(set) var pendingHardwareConnection: HardwareConnectionPrompt?
    private var declinedHardwareConnectionRoute: MIDIConnectionSnapshot?
    private var connectionOfferTask: Task<Void, Never>?
    private var startupTaskID: UUID?
    private var startupRoute: MIDIConnectionSnapshot?
    private(set) var observedHardwareGroup: Int?
    @Published private(set) var connectingHardware = false
    @Published private(set) var startingMIDI = false
    private var hardwareConnectionTask: Task<Void, Never>?
    private var midiInitializationTask: Task<Void, Never>?
    var backgroundTasks: [Task<Void, Never>] {
        [midiInitializationTask, connectionOfferTask, hardwareConnectionTask].compactMap { $0 }
    }

    var hasConnectionOffer: Bool { connectionOfferTask != nil }
    var presetSourceSwitchBlocked: Bool { preset.presetSourceSwitchBlocked }
    init(context: ConsoleDeviceContext, endpointStore: JSONFileStore<MIDIEndpointSelection>,
         selection: MIDIEndpointSelection, endpointError: LocalizedMessage?, output: OutputController,
         preset: any ConsoleConnectionPresetPort, recovery: any ConsoleConnectionRecoveryPort)
    {
        self.context = context; self.endpointStore = endpointStore; self.endpointSelection = selection
        self.endpointError = endpointError; endpointSettingsNeedRepair = endpointError != nil
        self.output = output; self.preset = preset; self.recovery = recovery
    }

    static func readSelection(_ store: JSONFileStore<MIDIEndpointSelection>)
        -> (selection: MIDIEndpointSelection, error: LocalizedMessage?)
    {
        do {
            let selection = try store.load() ?? MIDIEndpointSelection()
            try selection.validate()
            return (selection, nil)
        } catch { return (.init(), "MIDI 端口设置读取失败：\(error: error)") }
    }

    func start() {
        midi.selectEndpoints(endpointSelection)
        startMIDIWithoutBlockingWindow()
    }

    func clearObservedGroup() { observedHardwareGroup = nil }
    func noteTouched(_ control: BCRControlID) {
        if source == .hardware, control.section == .pushEncoder || control.section == .pushEncoderButton {
            observedHardwareGroup = control.row
        }
    }

    private func startMIDIWithoutBlockingWindow() {
        guard midiInitializationTask == nil else { return }
        startingMIDI = true
        let progress = ConsoleNotice(level: .info, message: "正在启动 MIDI 服务；界面可继续使用，请等待设备就绪。")
        if notice == nil { notice = progress }
        // Start system initialization now; the task below runs only after the first window layout.
        midi.beginStartup()
        midiInitializationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startingMIDI = false; self.midiInitializationTask = nil }
            do {
                try await self.midi.startWhenReady()
                if self.notice == progress { self.notice = nil }
                // The connection event usually offered already; restarting it would only re-wait the settle delay.
                if self.connection.isConnected, self.connectionOfferTask == nil, self.pendingHardwareConnection == nil {
                    self.offerHardwareConnection()
                }
            } catch { self.notice = ConsoleNotice(level: .error, message: "CoreMIDI 启动失败：\(error: error)") }
        }
    }

    func applyEndpointSelection(_ selection: MIDIEndpointSelection) {
        guard canConfigureMIDI else {
            notice = ConsoleNotice(level: .warning, message: "隔离测试未启用实体 MIDI")
            return
        }
        do { try commitEndpointSelection(selection) } catch { report(error) }
    }

    func commitEndpointSelection(_ selection: MIDIEndpointSelection) throws {
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

    func selectSource(_ newSource: DeviceSource) {
        guard !presetSourceSwitchBlocked else {
            notice = ConsoleNotice(level: .warning, message: "预设操作尚未结束，暂不能切换设备来源。")
            return
        }
        connectionOfferTask?.cancel(); connectionOfferTask = nil
        pendingHardwareConnection = nil; declinedHardwareConnectionRoute = nil
        preset.clearNumberContext()
        preset.invalidateDisplayNumber()
        presentation.clearDisplayedValue()
        presentation.clearHardwarePresses()
        hardwareConnectionTask?.cancel()
        hardwareConnectionTask = nil
        startupTaskID = nil; startupRoute = nil
        connectingHardware = false
        observedHardwareGroup = nil
        session.selectSource(newSource)
    }

    func offerHardwareConnection() {
        guard canConfigureMIDI, source == .mock, connection.isConnected, hardwareSwitchWrites,
              !connectingHardware, !presetSourceSwitchBlocked else { return }
        connectionOfferTask?.cancel()
        declinedHardwareConnectionRoute = nil
        let route = connection
        notice = ConsoleNotice(level: .info, message: "检测到硬件，等待连接稳定…")
        connectionOfferTask = Task { @MainActor [weak self, timing] in
            do { try await timing.work.sleep(ConsoleTiming.connection) } catch { return }
            guard let self else { return }
            defer { self.connectionOfferTask = nil }
            guard self.source == .mock, self.connection.isConnected,
                  self.connection.hasSameRoute(as: route) else { return }
            guard self.hardwareSwitchWrites else { return }
            self.pendingHardwareConnection = HardwareConnectionPrompt(
                route: self.connection,
                canRead: self.midi.supportsSnapshotReadback && !self.readableEncoders.isEmpty
            )
            self.notice = ConsoleNotice(level: .info, message: "请选择如何连接硬件；确认前不会写入设备。")
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
        if mode == .read, !prompt.canRead { return }
        declinedHardwareConnectionRoute = nil
        pendingHardwareConnection = nil
        let operation = UUID(), route = connection
        startupTaskID = operation; startupRoute = route
        connectingHardware = true
        let parameterRevision = session.parameterSnapshot().revision
        let configurationRevision = session.configurationRevision
        let previousDisplayTask = preset.displayReadTask
        let previousAlignmentTask = preset.alignmentTask
        let previousRestoreTask = recovery.restoreTask
        previousDisplayTask?.cancel()
        if mode == .write, previousDisplayTask == nil, previousAlignmentTask == nil, previousRestoreTask == nil {
            startupTaskID = nil; startupRoute = nil; connectingHardware = false
            session.selectSource(.hardware)
            return
        }
        notice = ConsoleNotice(
            level: .info,
            message: previousDisplayTask != nil || previousAlignmentTask != nil || previousRestoreTask != nil
                ? "等待设备完成上一轮预设发送，请暂勿操作设备…"
                : "正在读取硬件当前值，请暂勿操作旋钮…"
        )
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
            await previousRestoreTask?.value
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
                self.notice = ConsoleNotice(level: .info, message: "正在读取硬件当前值，请暂勿操作旋钮…")
                let expected = self.readableEncoders
                let messages = try await self
                    .withDisplayTransfer { try await self.midi.readSnapshot(expected: expected) }
                try Task.checkCancellation()
                guard self.source == .mock, self.connection.isConnected, self.connection.hasSameRoute(as: route),
                      self.session.parameterSnapshot().revision == parameterRevision,
                      self.session.configurationRevision == configurationRevision
                else { throw HardwareSnapshotError.invalid }
                try self.session.adoptHardwareSnapshot(messages)
                self.observedHardwareGroup = nil
                self.notice = ConsoleNotice(level: .info, message: "已读取硬件当前值；分组尚未确认，转动一个顶部旋钮即可跟随。")
            } catch is CancellationError {
                guard self.startupTaskID == operation else { return }
                if self.connection.isConnected == false {
                    self.notice = ConsoleNotice(level: .warning, message: "设备已断开，硬件同步已取消；重连后请重新确认。")
                }
            } catch {
                guard self.startupTaskID == operation else { return }
                self.notice = ConsoleNotice(level: .error, message: "硬件连接失败：\(error: error)")
            }
        }
    }

    var hardwareConnectionConfirmation: HardwareConnectionConfirmation {
        guard source == .mock, connection.isConnected else { return .none }
        // Include the existing stabilization delay so a just-refused MCP call can immediately be polled.
        if pendingHardwareConnection != nil || connectionOfferTask != nil { return .pending }
        return declinedHardwareConnectionRoute?.hasSameRoute(as: connection) == true ? .declined : .none
    }

    var hardwareSwitchWrites: Bool {
        session.learnedHardwareMap.entries.contains { $0.visualizationOnly != true }
    }

    private var readableEncoders: Set<MIDIControlID> {
        Set(session.learnedHardwareMap.entries.filter { $0.control.isContinuous }.map(\.midi))
    }

    func validateConnectionWork() {
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
}
