import BCRFoundation
import Foundation
import enum ParameterOutputPlugin.MotionOutputPrecision

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

    public var shared: SharedMotionLimit {
        .init(
            id: id,
            minimum: minimum,
            maximum: maximum,
            maximumChange: maximumChange,
            maximumVelocity: maximumVelocity
        )
    }

    public func validate() throws { try withLegacyOutputErrors { try shared.validate() } }
}

public struct ParameterSample: Equatable, Sendable {
    public let id: ParameterID
    public let value: Double
    public let receivedAt: Date
    public init(id: ParameterID, value: Double, receivedAt: Date) {
        self.id = id; self.value = value; self.receivedAt = receivedAt
    }

    public var shared: SharedParameterSample { .init(
        id: id,
        value: value,
        receivedAt: receivedAt.timeIntervalSinceReferenceDate
    ) }
    public init(shared: SharedParameterSample) { self.init(
        id: shared.id,
        value: shared.value,
        receivedAt: Date(timeIntervalSinceReferenceDate: shared.receivedAt)
    ) }
}

@MainActor public protocol ParameterSink: AnyObject {
    var isConnected: Bool { get }
    func send(_ frame: ParameterOutputFrame) throws
}

@MainActor public protocol ParameterSource: AnyObject {
    var onSamples: (@MainActor ([ParameterSample]) -> Void)? { get set }
    var onHeartbeat: (@MainActor (Date) -> Void)? { get set }
}

public struct MotionSafetyDecision: Equatable, Sendable {
    public let status: MotionGateStatus
    public let reason: String
    public let command: ParameterOutputFrame?
    public let limited: Bool
    public let parameterID: ParameterID?
    public init(shared: SharedMotionSafetyDecision) {
        status = legacyMotionStatus(shared.status)
        reason = legacyOutputReason(shared.reason, parameterID: shared.parameterID)
        command = shared.command; limited = shared.limited; parameterID = shared.parameterID
    }
}

/// Date-based legacy facade; the one mutable policy value is the shared output plugin.
public struct MotionSafetyGate: Sendable {
    public var plugin: SharedParameterOutputPlugin
    public var limits: [MotionLimit] { plugin.gate.limits.map { .init(
        id: $0.id,
        minimum: $0.minimum,
        maximum: $0.maximum,
        maximumChange: $0.maximumChange,
        maximumVelocity: $0.maximumVelocity
    ) } }
    public var heartbeatTimeout: TimeInterval { plugin.gate.heartbeatTimeout }
    public var status: MotionGateStatus { legacyMotionStatus(plugin.gate.status) }
    public var outputs: [ParameterID: Double] { plugin.gate.outputs }
    public var baseline: [ParameterID: Double] { plugin.gate.baseline }
    public init(
        limits: [MotionLimit],
        heartbeatTimeout: TimeInterval = 0.3,
        precision: MotionOutputPrecision = .double
    ) throws {
        plugin = try withLegacyOutputErrors { try SharedParameterOutputPlugin(
            limits: limits.map(\.shared),
            heartbeatTimeout: heartbeatTimeout,
            precision: precision
        ) }
        _ = try plugin.handle(.start, at: 0)
    }

    public init(plugin: SharedParameterOutputPlugin) { self.plugin = plugin }
    public mutating func setConnected(_ connected: Bool, at now: Date) { plugin.setConnected(
        connected,
        at: now.timeIntervalSinceReferenceDate
    ) }
    public mutating func receiveHeartbeat(at now: Date) {
        plugin.receiveHeartbeat(at: now.timeIntervalSinceReferenceDate)
    }

    public mutating func receiveActual(_ samples: [ParameterSample]) { plugin.receiveActual(samples.map(\.shared)) }
    public mutating func evaluate(targets: [ParameterID: Double], enabled: Bool, at now: Date) -> MotionSafetyDecision {
        if plugin.isStarted {
            do { try plugin.setEnabled(enabled) }
            catch { return .init(shared: .init(
                status: .disabled,
                reason: String(describing: error),
                command: .init(enabled: false, values: [:]),
                limited: false
            )) }
        }
        return evaluateRequested(targets: targets, at: now)
    }

    public mutating func setRequestedEnabled(_ enabled: Bool) throws { try plugin.setEnabled(enabled) }
    public mutating func evaluateRequested(targets: [ParameterID: Double], at now: Date) -> MotionSafetyDecision {
        .init(shared: plugin.evaluate(targets: targets, at: now.timeIntervalSinceReferenceDate))
    }
}
