import Foundation

public struct MotionLimit: Codable, Equatable, Sendable, Identifiable {
    public let id: ParameterID
    public var minimum: Double
    public var maximum: Double
    public var maximumChange: Double
    public var maximumVelocity: Double

    public init(id: ParameterID, minimum: Double, maximum: Double, maximumChange: Double, maximumVelocity: Double) {
        self.id = id; self.minimum = minimum; self.maximum = maximum
        self.maximumChange = maximumChange; self.maximumVelocity = maximumVelocity
    }

    public func validate() throws {
        guard minimum.isFinite, maximum.isFinite, minimum < maximum, (maximum - minimum).isFinite,
              maximumChange.isFinite, maximumChange > 0, maximumVelocity.isFinite, maximumVelocity > 0 else {
            throw MotionSafetyError("限位、单周期变化量和速度必须是有效的有限数值")
        }
    }
}

public struct MotionSafetyError: Error, LocalizedError, Equatable, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(_ reason: String) { self.reason = reason }
}

public struct ParameterSample: Equatable, Sendable {
    public let id: ParameterID
    public let value: Double
    public let receivedAt: Date
    public init(id: ParameterID, value: Double, receivedAt: Date) {
        self.id = id; self.value = value; self.receivedAt = receivedAt
    }
}

public struct ParameterOutputFrame: Equatable, Sendable {
    public let enabled: Bool
    public let values: [ParameterID: Double]
    public init(enabled: Bool, values: [ParameterID: Double]) { self.enabled = enabled; self.values = values }
}

@MainActor
public protocol ParameterSink: AnyObject {
    var isConnected: Bool { get }
    func send(_ frame: ParameterOutputFrame) throws
}

@MainActor
public protocol ParameterSource: AnyObject {
    var onSamples: (@MainActor ([ParameterSample]) -> Void)? { get set }
    var onHeartbeat: (@MainActor (Date) -> Void)? { get set }
}

public enum MotionGateStatus: String, Codable, Equatable, Sendable {
    case disconnected, disabled, waitingHeartbeat, heartbeatExpired, waitingActual, actualOutOfLimits
    case invalidTarget, invalidActual, clockError, waitingRearm, ready
}

public enum MotionOutputPrecision: Sendable { case double, float32 }

public struct MotionSafetyDecision: Equatable, Sendable {
    public let status: MotionGateStatus
    public let reason: String
    public let command: ParameterOutputFrame?
    public let limited: Bool
}

public struct MotionSafetySnapshot: Equatable, Sendable {
    public let status: MotionGateStatus
    public let reason: String
    public let outputs: [ParameterID: Double]
    public let actual: [ParameterID: Double]
    public let limited: Bool
    public let baseline: [ParameterID: Double]
    public init(status: MotionGateStatus, reason: String, outputs: [ParameterID: Double],
                actual: [ParameterID: Double], limited: Bool, baseline: [ParameterID: Double] = [:]) {
        self.baseline = baseline
        self.status = status; self.reason = reason; self.outputs = outputs
        self.actual = actual; self.limited = limited
    }
}

/// Clock-injected safety state; no network or UI. Only returned commands may reach a sink.
public struct MotionSafetyGate: Sendable {
    public let limits: [MotionLimit]
    public let heartbeatTimeout: TimeInterval
    public private(set) var status: MotionGateStatus = .disconnected
    public private(set) var outputs: [ParameterID: Double] = [:]
    public private(set) var baseline: [ParameterID: Double] = [:]
    private let precision: MotionOutputPrecision
    private var observedDisabled = false
    private var armed = false
    private var connected = false
    private var connectedAt: Date?
    private var heartbeat: Date?
    private var actual: [ParameterID: ParameterSample] = [:]
    private var lastStep: Date?
    private var fault: String?
    private var faultStatus: MotionGateStatus = .invalidActual

    public init(limits: [MotionLimit], heartbeatTimeout: TimeInterval = 0.3,
                precision: MotionOutputPrecision = .double) throws {
        guard !limits.isEmpty, Set(limits.map(\.id)).count == limits.count,
              heartbeatTimeout.isFinite, heartbeatTimeout > 0, heartbeatTimeout <= 0.45 else {
            throw MotionSafetyError("安全门需要非空、唯一的限位与不超过 450 ms 的心跳期限")
        }
        for limit in limits { try limit.validate() }
        self.limits = limits
        self.heartbeatTimeout = heartbeatTimeout
        self.precision = precision
    }

    public mutating func setConnected(_ value: Bool, at now: Date) {
        if value != connected {
            observedDisabled = false
            armed = false
            heartbeat = nil
            actual.removeAll()
            lastStep = now
            connectedAt = value ? now : nil
            fault = nil
            faultStatus = .invalidActual
        }
        connected = value
    }

    public mutating func receiveHeartbeat(at now: Date) {
        guard connected else { return }
        heartbeat = now
    }

    public mutating func receiveActual(_ samples: [ParameterSample]) {
        let allowed = Set(limits.map(\.id))
        for sample in samples where allowed.contains(sample.id) {
            guard sample.value.isFinite else { fault = "实际状态含非有限数值"; continue }
            if let old = actual[sample.id], sample.receivedAt < old.receivedAt { continue }
            actual[sample.id] = sample
        }
    }

    public mutating func evaluate(targets: [ParameterID: Double], enabled: Bool, at now: Date) -> MotionSafetyDecision {
        let previous = status
        let elapsed = lastStep.map { now.timeIntervalSince($0) } ?? 0
        lastStep = now
        func stopped(_ state: MotionGateStatus, _ reason: String) -> MotionSafetyDecision {
            MotionSafetyDecision(status: state, reason: reason,
                command: previous == .ready || (connected && heartbeat != nil) ? ParameterOutputFrame(enabled: false, values: [:]) : nil, limited: false)
        }
        if elapsed < 0 { fault = "时钟倒退，需重新连接安全门"; faultStatus = .clockError }
        let closed: MotionSafetyDecision?
        if !connected { closed = stopped(.disconnected, "适配器未连接，禁止输出") }
        else if let fault { closed = stopped(faultStatus, fault) }
        else if let heartbeat {
            let age = now.timeIntervalSince(heartbeat)
            if age < 0 { closed = stopped(.clockError, "心跳时间异常，禁止输出") }
            else if age >= heartbeatTimeout { closed = stopped(.heartbeatExpired, "心跳超时，已停止输出") }
            else { closed = nil }
        } else if connectedAt.map({ now.timeIntervalSince($0) >= heartbeatTimeout }) == true {
            closed = stopped(.heartbeatExpired, "未收到对端心跳，已停止输出")
        } else { closed = stopped(.waitingHeartbeat, "等待对端心跳") }
        if let closed { armed = false; observedDisabled = false; status = closed.status; return closed }
        if !enabled {
            armed = false
            observedDisabled = true
            let result = stopped(.disabled, "使能关闭，禁止运动输出")
            status = result.status
            return result
        }

        for limit in limits {
            guard let sample = actual[limit.id], now.timeIntervalSince(sample.receivedAt) >= 0,
                  now.timeIntervalSince(sample.receivedAt) < heartbeatTimeout else {
                let result = stopped(.waitingActual, "等待新鲜实际状态：\(limit.id)")
                armed = false; observedDisabled = false
                status = result.status; return result
            }
            guard sample.value >= limit.minimum, sample.value <= limit.maximum else {
                let result = stopped(.actualOutOfLimits, "实际状态超出软限位：\(limit.id)")
                armed = false; observedDisabled = false
                status = result.status; return result
            }
            guard let target = targets[limit.id], target.isFinite else {
                let result = stopped(.invalidTarget, "目标缺失或不是有限数值：\(limit.id)")
                armed = false; observedDisabled = false
                status = result.status; return result
            }
        }
        if !armed {
            guard observedDisabled else {
                let result = stopped(.waitingRearm, "请先关闭再开启使能，禁止自动恢复运动")
                status = result.status
                return result
            }
            armed = true
            observedDisabled = false
        }
        if previous != .ready {
            outputs = Dictionary(uniqueKeysWithValues: limits.map { ($0.id, actual[$0.id]!.value) })
            baseline = outputs
        }
        var limited = false
        for limit in limits {
            let previousOutput = outputs[limit.id]!
            let target = targets[limit.id]!
            let distance = previous == .ready ? min(limit.maximumChange, limit.maximumVelocity * elapsed) : 0
            let lower = max(limit.minimum, previousOutput - distance)
            let upper = min(limit.maximum, previousOutput + distance)
            let candidate = min(max(target, lower), upper)
            let next = quantized(candidate, lower: lower, upper: upper, previous: previousOutput)
            outputs[limit.id] = next
            limited = limited || next != target
        }
        status = .ready
        let command = ParameterOutputFrame(enabled: true, values: outputs)
        return MotionSafetyDecision(status: .ready, reason: limited ? "限位 / 限速中" : "输出已就绪",
                                    command: command, limited: limited)
    }

    private func quantized(_ value: Double, lower: Double, upper: Double, previous: Double) -> Double {
        guard precision == .float32 else { return value }
        var result = Float(value)
        if Double(result) > upper { result = result.nextDown }
        if Double(result) < lower { result = result.nextUp }
        let output = Double(result)
        // If a cycle's permitted interval is narrower than a float ULP, hold position.
        return output.isFinite && output >= lower && output <= upper ? output : previous
    }
}
