import BCRFoundation
import Foundation
import SurfaceBindingContext

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
struct FeedbackPlan: Equatable, Sendable {
    let message: MIDIVoiceMessage
    let origin: SurfaceWriteOrigin
    let timing: FeedbackTiming
}

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

    func message(_ message: MIDIVoiceMessage, origin: SurfaceWriteOrigin,
                 requestedTiming: FeedbackTiming?) -> FeedbackPlan
    {
        FeedbackPlan(message: message, origin: origin,
                     timing: requestedTiming ?? activeBatch?.timing ?? .coalesced)
    }
}

/// Invocation-local receipt. Nested operations never inherit or overwrite this collector.
@MainActor
final class FeedbackReceipt {
    var deliveries: [FeedbackDelivery?] = []
    var completionError: (any Error)?
    let accepted: (@MainActor () throws -> Void)?
    init(accepted: (@MainActor () throws -> Void)? = nil) { self.accepted = accepted }
    func record(_ delivery: FeedbackDelivery?) {
        deliveries.append(delivery)
        if delivery == .sent {
            do { try accepted?() } catch { completionError = error }
        }
    }
}

enum FeedbackDispatch: Equatable, Sendable { case enqueue, send }

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
    private var pending: [MIDIControlID: ScheduledFeedback] = [:]
    private var kernelIndex = ContextResourceIndex<MIDIControlID, BCRFeedbackQueueScope>()
    private let kernelTraceID = UUID().uuidString
    private var tokens: Double
    private var lastRefill: Date?
    private var retryAfter: Date?
    public var count: Int { kernelIndex.count }
    public var pendingItems: [ScheduledFeedback] { kernelIndex.orderedIDs.compactMap { pending[$0] } }
    public init(policy: FeedbackPolicy) throws {
        try policy.validate()
        self.policy = policy
        tokens = Double(policy.burst)
        if SurfaceKernelTrace.enabled { traceIndex("index.init", input: [:]) }
    }

    private func traceIndex(_ operation: String, input: [String: Any], removed: [MIDIControlID] = []) {
        SurfaceKernelTrace.record(
            operation, owner: kernelTraceID, input: input,
            actual: ["ids": kernelIndex.orderedIDs.map(BCRKernelProjection.midiValue), "count": kernelIndex.count,
                     "scopes": kernelIndex.orderedIDs
                         .map { BCRKernelProjection.queueScopeValue(kernelIndex.scope(for: $0)!) },
                     "removed": removed.map(BCRKernelProjection.midiValue)]
        )
    }

    /// Shared routing decision for normal and acknowledged display plans. A synchronous
    /// plan leaves the token bucket and any earlier queued value untouched, as before.
    static func dispatch(_ plan: FeedbackPlan, canCoalesce: Bool) -> FeedbackDispatch {
        canCoalesce && plan.timing == .coalesced ? .enqueue : .send
    }

    public mutating func enqueue(_ message: MIDIVoiceMessage, origin: SurfaceWriteOrigin,
                                 endpoint: MIDIEndpointSource? = nil, mappingRevision: UInt64? = nil,
                                 source: DeviceSource? = nil, context: SurfaceEventContext? = nil)
    {
        pending[message.controlID] = ScheduledFeedback(
            message: message,
            origin: origin,
            endpoint: endpoint,
            mappingRevision: mappingRevision,
            source: source,
            context: context
        )
        let scope = BCRFeedbackQueueScope(pending[message.controlID]!)
        kernelIndex.upsert(message.controlID, scope: scope)
        if SurfaceKernelTrace.enabled {
            traceIndex("index.upsert", input: ["id": BCRKernelProjection.midiValue(message.controlID),
                                               "scope": BCRKernelProjection.queueScopeValue(scope)])
        }
    }

    public mutating func cancel(_ control: MIDIControlID) {
        let removed = kernelIndex.remove(control) ? [control] : []
        pending[control] = nil
        if SurfaceKernelTrace.enabled {
            traceIndex("index.remove", input: ["id": BCRKernelProjection.midiValue(control)], removed: removed)
        }
    }

    public mutating func drain(at now: Date) -> [ScheduledFeedback] {
        if let previous = lastRefill {
            let elapsed = now.timeIntervalSince(previous)
            tokens = elapsed < 0 ? 0 : min(Double(policy.burst), tokens + elapsed * Double(policy.messagesPerSecond))
        }
        lastRefill = now
        if let retryAfter, now < retryAfter { return [] }
        let amount = min(Int(tokens), kernelIndex.count)
        let removed = try! kernelIndex.removeFirst(amount)
        var result: [ScheduledFeedback] = []
        for id in removed { if let value = pending.removeValue(forKey: id) { result.append(value) } }
        tokens -= Double(result.count)
        if SurfaceKernelTrace.enabled {
            traceIndex("index.removeFirst", input: ["amount": amount, "at": now.timeIntervalSinceReferenceDate],
                       removed: removed)
        }
        return result
    }

    public mutating func noteFailure(at now: Date) { retryAfter = now.addingTimeInterval(policy.errorCooldown) }
    public mutating func clear() {
        let removed = kernelIndex.removeAll()
        pending.removeAll(); lastRefill = nil; retryAfter = nil; tokens = Double(policy.burst)
        if SurfaceKernelTrace.enabled { traceIndex("index.removeAll", input: [:], removed: removed) }
    }
}

public enum FeedbackDelivery: String, Equatable, Sendable {
    case sent, disconnected, failed
    /// Held back by an observe-only hardware output policy; never reached the device.
    case suppressed
}
