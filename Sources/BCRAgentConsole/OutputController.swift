import BCRAgentCore
import Combine
import Foundation

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
                  Float(limit.minimum).isFinite, Float(limit.maximum).isFinite
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
    private var gate: MotionSafetyGate?
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
        now: @escaping @MainActor () -> Date = { .now }
    ) {
        self.session = session; self.store = store; self.adapter = adapter; self.now = now
        self.automaticallyTicks = automaticallyTicks
        configuration = session.engine.configuration
        configurationRevision = session.configurationRevision
        settings = .defaults(for: configuration)
        do { if let stored = try store.load() { settings = stored } }
        catch { self.error = L10n.text("输出设置读取失败：\(error.localizedDescription)") }
        session.setOutputEnableParameter(settings.enableParameter)
        adapter.onConnection = { [weak self] connected, failure in
            guard let self, !self.isStopping else { return }
            if let failure { self.stop(failure: failure); return }
            self.gate?.setConnected(connected, at: self.now())
            self.tick()
        }
        adapter.onHeartbeat = { [weak self] received in self?.gate?.receiveHeartbeat(at: received) }
        adapter.onSamples = { [weak self] in self?.receive($0) }
        adapter.onDroppedPacket = { [weak self] in self?.droppedPackets += 1 }
        adapter.onPeerReset = { [weak self] received in
            guard let self else { return }
            self.gate?.setConnected(false, at: received)
            self.tick()
            self.gate?.setConnected(true, at: received)
        }
        adapter.onFailure = { [weak self] in self?.stop(failure: $0) }
        publishSnapshot()
    }

    deinit { task?.cancel() }

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
            let gate = try MotionSafetyGate(limits: settings.limits, precision: .float32)
            var candidate = settings
            candidate.enabled = true
            try store.save(candidate)
            settings = candidate
            self.gate = gate
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
        settings.enabled = false
        settings.ledSource = .target
        adapter.stop()
        gate?.setConnected(false, at: now())
        status = .disconnected
        limited = false
        reason = failure.map { $0 + L10n.text("；输出已停止，LED 恢复目标值") } ?? L10n.text("输出已停止，LED 恢复目标值")
        error = failure
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
            gate?.receiveActual(samples)
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
        guard settings.enabled, var gate else { return }
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
            let decision = gate.evaluate(targets: targets, enabled: enabled, at: time)
            self.gate = gate
            if let command = decision.command, adapter.isConnected { try adapter.send(command) }
            if status != decision.status { status = decision.status }
            if reason != decision.reason { reason = decision.reason }
            if outputs != gate.outputs { outputs = gate.outputs }
            if limited != decision.limited { limited = decision.limited }
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
