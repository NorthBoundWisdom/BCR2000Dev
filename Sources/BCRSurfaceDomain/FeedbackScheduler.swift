import BCRFoundation
import Foundation
import SurfaceBindingContext
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
    private var records: [(fact: FeedbackReceiptFact<BCRFeedbackPlan>, delivery: FeedbackDelivery?)] = []
    var deliveries: [FeedbackDelivery?] { records.map(\.delivery) }
    var summary: FeedbackReceiptSummary { FeedbackReceiptSummary(records.map { $0.fact.result }) }
    var completionError: (any Error)?
    let accepted: (@MainActor () throws -> Void)?
    init(accepted: (@MainActor () throws -> Void)? = nil) { self.accepted = accepted }
    func record(_ fact: FeedbackReceiptFact<BCRFeedbackPlan>, delivery: FeedbackDelivery?) {
        records.append((fact, delivery))
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
    private var pending: [MIDIControlID: ScheduledFeedback] = [:]
    private var kernelIndex = ContextResourceIndex<MIDIControlID, BCRFeedbackQueueScope>()
    private let kernelTraceID = UUID().uuidString
    private var tokens: Double
    private var lastRefill: Date?
    private var retryAfter: Date?
    private(set) var j4LastDrainOrdinal: UInt64?
    var j4Owner: String { kernelTraceID }
    public var count: Int { kernelIndex.count }
    public var pendingItems: [ScheduledFeedback] { kernelIndex.orderedIDs.compactMap { pending[$0] } }
    public init(policy: FeedbackPolicy) throws {
        try policy.validate()
        self.policy = policy
        tokens = Double(policy.burst)
        if SurfaceKernelTrace.enabled { traceIndex("index.init", input: [:]) }
        let ordinal = FeedbackJ4Trace.schedulerInput(
            owner: kernelTraceID,
            operation: "initialize",
            context: ["native_policy": FeedbackJ4Trace.policy(policy)]
        ) {
            ["rate": ["kind": "bucket", "per_second": Double(policy.messagesPerSecond),
                      "burst": policy.burst, "error_cooldown": policy.errorCooldown]]
        }
        FeedbackJ4Trace.schedulerOutput(owner: kernelTraceID, ordinal: ordinal) { j4Output() }
    }

    private func j4Output(drained: [ScheduledFeedback] = [], removed: [String] = [],
                          replaced: [String] = []) -> [String: Any]
    {
        ["pending": pendingItems.map(FeedbackJ4Trace.entry), "drained": drained.map(FeedbackJ4Trace.entry),
         "removed_keys": removed, "replaced_keys": replaced,
         "tokens": tokens, "refill": lastRefill.map { $0.timeIntervalSinceReferenceDate } as Any? ?? NSNull(),
         "retry": retryAfter.map { $0.timeIntervalSinceReferenceDate } as Any? ?? NSNull()]
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

    public mutating func enqueue(_ message: MIDIVoiceMessage, origin: SurfaceWriteOrigin,
                                 endpoint: MIDIEndpointSource? = nil, mappingRevision: UInt64? = nil,
                                 source: DeviceSource? = nil, context: SurfaceEventContext? = nil,
                                 callerRequeueCauseOrdinal: UInt64? = nil, parentIntent: UInt64? = nil,
                                 parentSession: String? = nil)
    {
        let argument = ScheduledFeedback(message: message, origin: origin, endpoint: endpoint,
                                         mappingRevision: mappingRevision, source: source, context: context)
        let ordinal = FeedbackJ4Trace.schedulerInput(
            owner: kernelTraceID,
            operation: "enqueue",
            context: ["parent_intent": parentSession
                .map { FeedbackJ4Trace.reference(owner: $0, ordinal: parentIntent) } ?? NSNull()]
        ) {
            ["item": FeedbackJ4Trace.entry(argument), "ingress": callerRequeueCauseOrdinal.map {
                ["kind": "derived_caller_requeue", "cause_ordinal": String($0)]
            } ?? ["kind": "external_request"]]
        }
        let replaced = pending[message.controlID] == nil ? [] : [FeedbackJ4Trace.key(message.controlID)]
        defer {
            FeedbackJ4Trace.schedulerOutput(owner: kernelTraceID, ordinal: ordinal) { j4Output(replaced: replaced) }
        }
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
        let ordinal = FeedbackJ4Trace
            .schedulerInput(owner: kernelTraceID, operation: "cancel") { ["key": FeedbackJ4Trace.key(control)] }
        var removedKeys: [String] = []
        defer {
            FeedbackJ4Trace.schedulerOutput(owner: kernelTraceID, ordinal: ordinal) { j4Output(removed: removedKeys) }
        }
        let removed = kernelIndex.remove(control) ? [control] : []
        removedKeys = removed.map(FeedbackJ4Trace.key)
        pending[control] = nil
        if SurfaceKernelTrace.enabled {
            traceIndex("index.remove", input: ["id": BCRKernelProjection.midiValue(control)], removed: removed)
        }
    }

    public mutating func drain(at now: Date) -> [ScheduledFeedback] {
        let ordinal = FeedbackJ4Trace
            .schedulerInput(owner: kernelTraceID, operation: "drain") { ["at": now.timeIntervalSinceReferenceDate] }
        j4LastDrainOrdinal = ordinal.map(UInt64.init)
        var result: [ScheduledFeedback] = []
        var removedKeys: [String] = []
        defer { FeedbackJ4Trace.schedulerOutput(owner: kernelTraceID, ordinal: ordinal) { j4Output(
            drained: result,
            removed: removedKeys
        ) } }
        if let previous = lastRefill {
            let elapsed = now.timeIntervalSince(previous)
            tokens = elapsed < 0 ? 0 : min(Double(policy.burst), tokens + elapsed * Double(policy.messagesPerSecond))
        }
        lastRefill = now
        if let retryAfter, now < retryAfter { return [] }
        let amount = min(Int(tokens), kernelIndex.count)
        let removed = try! kernelIndex.removeFirst(amount)
        removedKeys = removed.map(FeedbackJ4Trace.key)
        for id in removed { if let value = pending.removeValue(forKey: id) { result.append(value) } }
        tokens -= Double(result.count)
        if SurfaceKernelTrace.enabled {
            traceIndex("index.removeFirst", input: ["amount": amount, "at": now.timeIntervalSinceReferenceDate],
                       removed: removed)
        }
        return result
    }

    public mutating func noteFailure(at now: Date) {
        let ordinal = FeedbackJ4Trace
            .schedulerInput(owner: kernelTraceID, operation: "failure") { ["at": now.timeIntervalSinceReferenceDate] }
        defer { FeedbackJ4Trace.schedulerOutput(owner: kernelTraceID, ordinal: ordinal) { j4Output() } }
        retryAfter = now.addingTimeInterval(policy.errorCooldown)
    }

    public mutating func clear() {
        let ordinal = FeedbackJ4Trace.schedulerInput(owner: kernelTraceID, operation: "clear") { [:] }
        var removedKeys: [String] = []
        defer {
            FeedbackJ4Trace.schedulerOutput(owner: kernelTraceID, ordinal: ordinal) { j4Output(removed: removedKeys) }
        }
        let removed = kernelIndex.removeAll()
        removedKeys = removed.map(FeedbackJ4Trace.key)
        pending.removeAll(); lastRefill = nil; retryAfter = nil; tokens = Double(policy.burst)
        if SurfaceKernelTrace.enabled { traceIndex("index.removeAll", input: [:], removed: removed) }
    }
}

public enum FeedbackDelivery: String, Equatable, Sendable {
    case sent, disconnected, failed
    /// Held back by an observe-only hardware output policy; never reached the device.
    case suppressed
}
