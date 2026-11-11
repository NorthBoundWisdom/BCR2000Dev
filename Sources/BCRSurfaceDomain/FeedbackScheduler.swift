import BCRFoundation
import Foundation

public struct FeedbackPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var messagesPerSecond: Int
    public var burst: Int
    public var errorCooldown: TimeInterval
    public init(enabled: Bool = false, messagesPerSecond: Int = 120, burst: Int = 4, errorCooldown: TimeInterval = 1) {
        self.enabled = enabled
        self.messagesPerSecond = messagesPerSecond
        self.burst = burst
        self.errorCooldown = errorCooldown
    }

    private enum CodingKeys: String, CodingKey { case enabled, messagesPerSecond, burst, errorCooldown }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        messagesPerSecond = try c.decode(Int.self, forKey: .messagesPerSecond)
        burst = try c.decode(Int.self, forKey: .burst)
        errorCooldown = try c.decode(TimeInterval.self, forKey: .errorCooldown)
        try validate()
    }

    public func validate() throws {
        guard (1 ... 1000).contains(messagesPerSecond), (1 ... 128).contains(burst),
              errorCooldown.isFinite, (0 ... 30).contains(errorCooldown)
        else {
            throw MotionSafetyError(L10n.text("反馈调度策略无效"))
        }
    }
}

public struct ScheduledFeedback: Equatable, Sendable {
    public let message: MIDIVoiceMessage
    public let origin: SurfaceWriteOrigin
}

/// Token-bucket scheduler. A pending control retains only its most recent desired value.
public struct FeedbackScheduler: Sendable {
    public let policy: FeedbackPolicy
    private var pending: [MIDIControlID: ScheduledFeedback] = [:]
    private var order: [MIDIControlID] = []
    private var tokens: Double
    private var lastRefill: Date?
    private var retryAfter: Date?
    public var count: Int { pending.count }
    public init(policy: FeedbackPolicy) throws {
        try policy.validate()
        self.policy = policy
        tokens = Double(policy.burst)
    }

    public mutating func enqueue(_ message: MIDIVoiceMessage, origin: SurfaceWriteOrigin) {
        if pending[message.controlID] == nil { order.append(message.controlID) }
        pending[message.controlID] = ScheduledFeedback(message: message, origin: origin)
    }

    public mutating func cancel(_ control: MIDIControlID) {
        pending[control] = nil
        order.removeAll { $0 == control }
    }

    public mutating func drain(at now: Date) -> [ScheduledFeedback] {
        if let previous = lastRefill {
            let elapsed = now.timeIntervalSince(previous)
            tokens = elapsed < 0 ? 0 : min(Double(policy.burst), tokens + elapsed * Double(policy.messagesPerSecond))
        }
        lastRefill = now
        if let retryAfter, now < retryAfter { return [] }
        let amount = min(Int(tokens), order.count)
        var result: [ScheduledFeedback] = []
        for id in order.prefix(amount) { if let value = pending.removeValue(forKey: id) { result.append(value) } }
        order.removeFirst(amount)
        tokens -= Double(result.count)
        return result
    }

    public mutating func noteFailure(at now: Date) { retryAfter = now.addingTimeInterval(policy.errorCooldown) }
    public mutating func clear() {
        pending.removeAll(); order.removeAll(); lastRefill = nil; retryAfter = nil; tokens = Double(policy.burst)
    }
}

public enum FeedbackDelivery: String, Equatable, Sendable {
    case sent, disconnected, failed
}
