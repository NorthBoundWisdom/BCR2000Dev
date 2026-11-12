import BCRAgentCore
import Combine
import Foundation
import BCRPluginRuntime
import OutputRemoteBinding

struct OutputSettings: Codable, Equatable, Sendable {
    var version = 1
    var transport: OutputTransportKind = .osc
    var enabled = false
    var host = "127.0.0.1"
    var port = 9000
    var enableParameter: ParameterID = ""
    var ledSource: LEDFeedbackSource = .target
    var limits: [MotionLimit] = []

    init() {}
    private enum CodingKeys: String,
        CodingKey { case version, enabled, host, port, enableParameter, ledSource, limits, transport }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        enableParameter = try c.decode(ParameterID.self, forKey: .enableParameter)
        ledSource = try c.decode(LEDFeedbackSource.self, forKey: .ledSource)
        limits = try c.decode([MotionLimit].self, forKey: .limits)
        transport = c.contains(.transport) ? try c.decode(OutputTransportKind.self, forKey: .transport) : .osc
    }

    static func defaults(for configuration: SurfaceConfiguration) -> OutputSettings {
        var settings = OutputSettings()
        settings.enableParameter = configuration.parameters.first(where: { $0.kind == .toggle })?.id ?? ""
        settings.limits = configuration.parameters.filter { $0.kind == .continuous }.map {
            .init(id: $0.id, minimum: $0.minimum, maximum: $0.maximum,
                  maximumChange: min(1, $0.maximum - $0.minimum),
                  maximumVelocity: min(45, ($0.maximum - $0.minimum) / 4))
        }
        return settings
    }

    func validate(configuration: SurfaceConfiguration) throws {
        guard version == 1, !host.isEmpty, host.utf8.count <= 255, !host.utf8.contains(0),
              (1_024 ... 65_535).contains(port) else { throw MotionSafetyError(L10n.text("输出地址、端口或设置版本无效")) }
        guard configuration.parameter(enableParameter)?.kind == .toggle
        else { throw MotionSafetyError(L10n.text("请配置一个开关类型的使能参数")) }
        for limit in limits {
            try limit.validate()
            guard let definition = configuration.parameter(limit.id), definition.kind == .continuous,
                  limit.minimum >= definition.minimum, limit.maximum <= definition.maximum,
                  (transport != .osc || (Float(limit.minimum).isFinite && Float(limit.maximum).isFinite))
            else {
                throw MotionSafetyError(L10n.text("输出限位必须属于现有连续参数的范围并可用 float32 表示"))
            }
        }
        _ = try MotionSafetyGate(limits: limits)
    }
}

@MainActor
final class OutputController: ObservableObject {
    @Published private(set) var settings: OutputSettings
    @Published private(set) var status: MotionGateStatus = .disconnected
    @Published private(set) var reason = L10n.text("输出关闭")
    @Published private(set) var outputs: [ParameterID: Double] = [:]
    @Published private(set) var actual: [ParameterID: Double] = [:]
    @Published private(set) var limited = false
    @Published private(set) var error: String?
    @Published private(set) var droppedPackets = 0
    let session: SurfaceSession
    private let adapter: any OutputTransport
    private let store: JSONFileStore<OutputSettings>
    let runtime: BCRPluginRuntime
    static let instanceID = OutputRemoteBinding.defaultInstanceID
    private var observer: UUID?
    private var wallAnchor: Date
    private var policyAnchor: Double
    private var observedEnable: Bool?
    private var gate: MotionSafetyGate? {
        runtime.optionalBinding(Self.instanceID, as: OutputRemoteBinding.self).map { .init(plugin: $0.plugin) }
    }

    private var configuration: SurfaceConfiguration
    private var configurationRevision: UInt64
    private var lastPing: Date?
    private var task: Task<Void, Never>?
    private var isStopping = false
    private let automaticallyTicks: Bool
    private let now: @MainActor () -> Date

    init(
        session: SurfaceSession,
        store: JSONFileStore<OutputSettings>,
        adapter: any OutputTransport = OutputTransportRouter(),
        automaticallyTicks: Bool = true,
        now: @escaping @MainActor () -> Date = { .now },
        runtime: BCRPluginRuntime? = nil
    ) {
        self.session = session; self.store = store; self.adapter = adapter; self.now = now
        do { self.runtime = try runtime ?? BCRPluginRuntime(clock: { now().timeIntervalSinceReferenceDate }) }
        catch { preconditionFailure("Invalid built-in output runtime: \(error)") }
        policyAnchor = self.runtime.now; wallAnchor = now()
        self.automaticallyTicks = automaticallyTicks
        configuration = session.engine.configuration
        configurationRevision = session.configurationRevision
        settings = .defaults(for: configuration)
        do { if let stored = try store.load() { settings = stored } }
        catch { self.error = L10n.text("输出设置读取失败：\(error.localizedDescription)") }
        session.setOutputEnableParameter(settings.enableParameter)
        // Output is physically inactive on construction. Valid settings may prepare a
        // discoverable policy, but invalid/unconfigured limits are reported only when
        // the operator explicitly starts output. A real settings read failure stays visible.
        let preparedGate: MotionSafetyGate?
        do {
            preparedGate = try MotionSafetyGate(
                limits: settings.limits, precision: settings.transport == .osc ? .float32 : .double
            )
        } catch is MotionSafetyError { preparedGate = nil }
        catch { preparedGate = nil; self.error = error.localizedDescription }
        if let preparedGate {
            do { try storeGate(preparedGate, operation: "configure") }
            catch { self.error = error.localizedDescription }
        }
        observer = self.runtime.observe { [weak self] change in
            guard let self, change.instanceID == Self.instanceID, change.isRemote else { return }
            self.applyRemoteDecision()
        }
        adapter.onConnection = { [weak self] connected, failure in
            guard let self, !self.isStopping else { return }
            if let failure { self.stop(failure: failure); return }
            if connected {
                self.policyAnchor = self.runtime.now; self.wallAnchor = self.now(); self.observedEnable = nil
            }
            do { try self.mutateGate("connection") { $0.setConnected(connected, at: self.policyNow) } }
            catch { self.stop(failure: error.localizedDescription); return }
            self.tick()
        }
        adapter.onHeartbeat = { [weak self] received in
            guard let self, self.settings.enabled, !self.isStopping else { return }
            do {
                try self.mutateGate("heartbeat", journal: false) { $0.receiveHeartbeat(at: self.policyTime(received)) }
            } catch { self.stop(failure: error.localizedDescription) }
        }
        adapter.onSamples = { [weak self] in self?.receive($0) }
        adapter.onDroppedPacket = { [weak self] in self?.droppedPackets += 1 }
        adapter.onPeerReset = { [weak self] received in
            guard let self else { return }
            do {
                try self.mutateGate("peer.disconnect") { $0.setConnected(false, at: self.policyNow) }
                self.tick()
                self.policyAnchor = self.runtime.now; self.wallAnchor = self.now(); self.observedEnable = nil
                try self.mutateGate("peer.connect") { $0.setConnected(true, at: self.policyNow) }
            } catch { self.stop(failure: error.localizedDescription) }
        }
        adapter.onFailure = { [weak self] in self?.stop(failure: $0) }
        publishSnapshot()
    }

    deinit {
        task?.cancel()
        let owner = runtime, token = observer
        Task { @MainActor in if let token { owner.removeObserver(token) } }
    }

    func restore() {
        // Restoring saved settings never reconnects an actuator or resumes motion.
        if settings.enabled {
            settings.enabled = false
            reason = L10n.text("上次输出未恢复；请手动启动并先关闭再开启使能")
            do { try store.save(settings) }
            catch { self.error = L10n.text("输出设置保存失败：\(error.localizedDescription)") }
        }
    }

    func start() {
        do {
            try settings.validate(configuration: session.engine.configuration)
            let gate = try MotionSafetyGate(
                limits: settings.limits,
                precision: settings.transport == .osc ? .float32 : .double
            )
            var candidate = settings
            candidate.enabled = true
            try store.save(candidate)
            settings = candidate
            policyAnchor = runtime.now; wallAnchor = now(); observedEnable = nil
            try storeGate(gate, operation: "configure")
            configuration = session.engine.configuration
            configurationRevision = session.configurationRevision
            session.setOutputEnableParameter(settings.enableParameter)
            outputs = [:]; actual = [:]; error = nil; lastPing = nil
            try adapter.select(settings.transport)
            try adapter.start(host: settings.host, port: UInt16(settings.port))
            task?.cancel()
            if automaticallyTicks { task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard self != nil else { return }
                    self?.tick()
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                }
            } }
        } catch { stop(failure: error.localizedDescription) }
    }

    func stop(failure: String? = nil) {
        guard !isStopping else { return }
        isStopping = true
        task?.cancel(); task = nil
        var closingFailure = failure
        settings.enabled = false
        settings.ledSource = .target
        adapter.stop()
        if var gate {
            do {
                _ = try runtime.handle(Self.instanceID, input: .stop)
                gate = self.gate ?? gate
                let safetyTime = Date(timeIntervalSinceReferenceDate: runtime.safetyTimestamp)
                gate.setConnected(false, at: safetyTime)
                _ = gate.evaluateRequested(targets: [:], at: safetyTime)
                try storeGate(gate, operation: "disconnect", safety: true)
            } catch { closingFailure = error.localizedDescription }
        }
        observedEnable = nil
        status = .disconnected
        limited = false
        reason = closingFailure.map { $0 + L10n.text("；输出已停止，LED 恢复目标值") } ?? L10n.text("输出已停止，LED 恢复目标值")
        error = closingFailure
        session.setLEDFeedbackSource(.target)
        do { try store.save(settings) }
        catch { self.error = reason + L10n.text("；设置保存失败：\(error.localizedDescription)") }
        publishSnapshot()
        isStopping = false
    }

    func apply(_ candidate: OutputSettings) {
        do {
            try candidate.validate(configuration: session.engine.configuration)
            let restart = settings.enabled
            if restart { stop() }
            var value = candidate
            value.enabled = false
            // Actual projection requires a live source; starting below installs it after fresh samples.
            try store.save(value)
            settings = value
            session.setOutputEnableParameter(value.enableParameter)
            error = nil
            if restart { start() }
            else { session.setLEDFeedbackSource(.target) }
        } catch { self.error = error.localizedDescription }
    }

    func setLEDSource(_ source: LEDFeedbackSource) {
        guard source != .actual ||
            (settings.enabled && !actual.isEmpty && status != .heartbeatExpired && status != .disconnected)
        else {
            error = L10n.text("实际回传尚未就绪，LED 来源未改变")
            return
        }
        var candidate = settings
        candidate.ledSource = source
        do {
            try store.save(candidate)
            settings = candidate
            session.setLEDFeedbackSource(source)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func receive(_ samples: [ParameterSample]) {
        guard settings.enabled else { return }
        let time = now()
        guard samples.allSatisfy({ $0.receivedAt <= time && time.timeIntervalSince($0.receivedAt) < 0.3 }) else {
            droppedPackets += 1
            return
        }
        do {
            var values: [ParameterID: Double] = [:]
            for sample in samples {
                guard session.engine.configuration.parameter(sample.id) != nil, sample.value.isFinite else {
                    throw MotionSafetyError(L10n.text("实际回传包含未知参数或非法数值"))
                }
                values[sample.id] = sample.value
            }
            let policySamples = samples.map { ParameterSample(
                id: $0.id,
                value: $0.value,
                receivedAt: policyTime($0.receivedAt)
            ) }
            try mutateGate("actual", journal: false) { $0.receiveActual(policySamples) }
            if values.contains(where: { actual[$0.key] != $0.value }) {
                actual.merge(values) { _, new in new }
                try session.setActualFeedback(values)
            }
            if settings.ledSource == .actual, session.engine.ledFeedbackSource != .actual {
                session.setLEDFeedbackSource(.actual)
            }
        } catch { stop(failure: error.localizedDescription) }
    }

    func tick() {
        guard settings.enabled else { return }
        guard var gate else { stop(failure: L10n.text("安全门尚未初始化")); return }
        let time = now()
        guard session.configurationRevision == configurationRevision,
              session.engine.configuration == configuration
        else {
            stop(failure: L10n.text("配置已变化，请确认使能和限位后重新启动输出"))
            return
        }
        if session.source == .hardware && !session.connection.isConnected {
            stop(failure: L10n.text("实体控制器断开"))
            return
        }
        do {
            if adapter.isConnected, lastPing == nil || time.timeIntervalSince(lastPing!) >= 0.1 {
                try adapter.ping(at: time)
                lastPing = time
            }
            let definition = session.engine.configuration.parameter(settings.enableParameter)!
            let enabled = (session.engine.value(of: definition.id) ?? definition.minimum) >= definition.midpoint
            let targets = Dictionary(uniqueKeysWithValues: settings.limits.compactMap { limit in
                session.engine.value(of: limit.id).map { (limit.id, $0) }
            })
            // Only a real host enable-parameter edge changes the requested flag. A remote
            // disable therefore persists until an actual off/on; polling cannot undo it.
            if observedEnable != enabled { try gate.setRequestedEnabled(enabled); observedEnable = enabled }
            let previous = gate.plugin.decision
            let decision = gate.evaluateRequested(targets: targets, at: policyNow)
            let current = gate.plugin.decision
            let changed = previous?.status != current?.status || previous?.reason != current?.reason ||
                previous?.parameterID != current?.parameterID || previous?.limited != current?.limited
            try storeGate(gate, operation: "evaluate", journal: changed)
            if let command = decision.command, adapter.isConnected { try adapter.send(command) }
            if status != decision.status { status = decision.status }
            let displayReason = decision.status == .disabled && enabled && !gate.plugin.requestedEnabled
                ? L10n.text("请先关闭再开启使能，禁止自动恢复运动") : decision.reason
            if reason != displayReason { reason = displayReason }
            if outputs != gate.outputs { outputs = gate.outputs }
            if limited != decision.limited { limited = decision.limited }
            publishSnapshot()
        } catch { stop(failure: error.localizedDescription) }
    }

    private var policyNow: Date { Date(timeIntervalSinceReferenceDate: runtime.now) }
    private func policyTime(_ date: Date) -> Date {
        // Preserve the original trusted timestamp/queue age, rather than marking delayed
        // callbacks fresh. Rebase only on a new connection or explicit configuration.
        Date(timeIntervalSinceReferenceDate: policyAnchor + date.timeIntervalSince(wallAnchor))
    }

    private func storeGate(
        _ gate: MotionSafetyGate,
        operation: String,
        safety: Bool = false,
        journal: Bool = true
    ) throws {
        let binding = OutputRemoteBinding(instanceID: Self.instanceID, plugin: gate.plugin)
        if runtime.optionalBinding(Self.instanceID, as: OutputRemoteBinding.self) == nil {
            try runtime.install([binding])
        } else if safety {
            try runtime.replaceForSafety(binding, event: .init(code: "host.safety.output." + operation))
        } else {
            try runtime.replace(binding, event: journal ? .init(code: "host.output." + operation) : nil)
        }
    }

    private func mutateGate(
        _ operation: String,
        journal: Bool = true,
        _ body: (inout MotionSafetyGate) throws -> Void
    ) throws {
        guard var gate else { throw MotionSafetyError(L10n.text("安全门尚未初始化")) }
        try body(&gate); try storeGate(gate, operation: operation, journal: journal)
    }

    private func applyRemoteDecision() {
        guard let gate, let core = gate.plugin.decision else { return }
        let decision = MotionSafetyDecision(shared: core)
        do {
            if let command = decision.command, adapter.isConnected { try adapter.send(command) }
            status = decision.status; reason = decision.reason; outputs = gate.outputs; limited = decision.limited
            publishSnapshot()
        } catch { stop(failure: error.localizedDescription) }
    }

    private func publishSnapshot() {
        session.setMotionSafety(.init(
            status: status,
            reason: reason,
            outputs: outputs,
            actual: actual,
            limited: limited,
            baseline: gate?.baseline ?? [:]
        ))
    }
}
