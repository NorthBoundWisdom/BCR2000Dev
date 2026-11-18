import BCRFoundation
import Foundation
import SurfaceFeedbackPlanning

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

/// Delivery timing belongs to the immutable effect plan, never to mutable session state.
/// Synchronous display requests preserve their existing transport-acknowledgement contract.
enum FeedbackTiming: Equatable, Sendable { case coalesced, synchronous }
/// One validated effect batch. Nested synchronous callbacks create child message plans
/// under the same delivery policy, while retaining their own current write origin.
struct FeedbackBatchPlan: Sendable {
    let effects: [SurfaceEffect]
    let origin: SurfaceWriteOrigin
    let timing: FeedbackTiming
}

@MainActor
final class FeedbackPlanner {
    private var activeBatch: FeedbackBatchPlan?

    func withBatch<Result>(_ batch: FeedbackBatchPlan, _ operation: () throws -> Result) rethrows -> Result {
        activeBatch = batch
        // Preserve the legacy boundary: completing any acknowledged display invalidates
        // the current synchronous cause, including an enclosing reentrant request. Do not
        // restore the parent here; that would expand when its later callbacks can send.
        defer { activeBatch = nil }
        return try operation()
    }

    func resolvedTiming(requested: FeedbackTiming?) -> FeedbackTiming {
        requested ?? activeBatch?.timing ?? .coalesced
    }
}

/// Invocation-local receipt. Nested operations never inherit or overwrite this collector.
@MainActor
final class FeedbackReceipt {
    private var records: [FeedbackReceiptFact<BCRFeedbackPlan>] = []
    var summary: FeedbackReceiptSummary { FeedbackReceiptSummary(records.map(\.result)) }
    var completionError: (any Error)?
    let accepted: (@MainActor () throws -> Void)?
    init(accepted: (@MainActor () throws -> Void)? = nil) { self.accepted = accepted }
    func record(_ fact: FeedbackReceiptFact<BCRFeedbackPlan>) {
        records.append(fact)
        if fact.successfulSend {
            do { try accepted?() } catch { completionError = error }
        }
    }
}

public struct ScheduledFeedback: Equatable, Sendable {
    public let message: MIDIVoiceMessage
    public let origin: SurfaceWriteOrigin
    public var endpoint: MIDIEndpointSource? = nil
    public var mappingRevision: UInt64? = nil
    public var source: DeviceSource? = nil
    public var context: SurfaceEventContext? = nil
}

/// Token-bucket scheduler. A pending control retains only its most recent desired value.
public struct FeedbackScheduler: Sendable {
    public let policy: FeedbackPolicy
    private var queue: FeedbackQueue<MIDIControlID, ScheduledFeedback>
    private enum ClockFault: Sendable {
        case drain(any Error)
        case failure(any Error)

        var error: any Error {
            switch self {
            case let .drain(error), let .failure(error): error
            }
        }
    }

    private var clockFault: ClockFault?
    var clockIssue: (any Error)? { clockFault?.error }
    public var count: Int { queue.count }
    public var pendingItems: [ScheduledFeedback] { queue.orderedEntries.map(\.item) }
    public init(policy: FeedbackPolicy) throws {
        try policy.validate()
        self.policy = policy
        queue = try FeedbackQueue(rate: .bucket(perSecond: Double(policy.messagesPerSecond), burst: policy.burst,
                                                failureCooldown: policy.errorCooldown))
    }

    public mutating func enqueue(_ message: MIDIVoiceMessage, origin: SurfaceWriteOrigin,
                                 endpoint: MIDIEndpointSource? = nil, mappingRevision: UInt64? = nil,
                                 source: DeviceSource? = nil, context: SurfaceEventContext? = nil)
    {
        let argument = ScheduledFeedback(message: message, origin: origin, endpoint: endpoint,
                                         mappingRevision: mappingRevision, source: source, context: context)
        queue.enqueue(argument, for: message.controlID)
    }

    public mutating func cancel(_ control: MIDIControlID) {
        queue.cancel(control)
    }

    public mutating func drain(at now: Date) -> [ScheduledFeedback] {
        drainForFlush(at: now).items
    }

    mutating func drainForFlush(at now: Date) -> (items: [ScheduledFeedback], failure: (any Error)?) {
        if case .failure? = clockFault { return ([], nil) }
        let instant = now.timeIntervalSinceReferenceDate
        let drained: [FeedbackQueueEntry<MIDIControlID, ScheduledFeedback>]
        do {
            drained = try queue.drain(at: instant)
            clockFault = nil
        } catch {
            clockFault = .drain(error)
            return ([], error)
        }
        return (drained.map(\.item), nil)
    }

    public mutating func noteFailure(at now: Date) {
        if case .failure? = clockFault { return }
        let instant = now.timeIntervalSinceReferenceDate
        do {
            try queue.noteFailure(at: instant)
            clockFault = nil
        } catch {
            // An invalid failure time cannot establish a cooldown deadline.
            clockFault = .failure(error)
            return
        }
    }

    public mutating func clear() {
        queue.clear()
        clockFault = nil
    }
}

public enum FeedbackDelivery: String, Equatable, Sendable {
    case sent, disconnected, failed
    /// Held back by an observe-only hardware output policy; never reached the device.
    case suppressed
}
