#if os(Linux)
    import Glibc
#else
    import Darwin
#endif
import Foundation
import SurfaceDeviceConformance
import SurfaceFeedbackPlanning

/// Audit identity is stricter than domain Equatable: preserve every string byte and Double bit.
enum J4ExactJSON {
    static func same(_ a: ScenarioPayload, _ b: ScenarioPayload) -> Bool {
        switch (a, b) {
        case let (.scalar(.number(x)), .scalar(.number(y))): return x.bitPattern == y.bitPattern
        case let (.scalar(.text(x)), .scalar(.text(y))): return text(x, y)
        case let (.scalar(.flag(x)), .scalar(.flag(y))): return x == y
        case (.scalar(.null), .scalar(.null)): return true
        case let (.array(x), .array(y)):
            guard x.count == y.count else { return false }
            for i in x.indices where !same(x[i], y[i]) { return false }
            return true
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            for (key, value) in x {
                guard let i = y.index(forKey: key), text(key, y[i].key), same(value, y[i].value) else { return false }
            }
            return true
        default: return false
        }
    }

    static func text(_ a: String, _ b: String) -> Bool {
        // Pointers live only inside standard-library contiguous UTF8 closures; nothing is retained.
        var a = a, b = b
        return a.withUTF8 { left in
            b.withUTF8 { right in
                guard left.count == right.count else { return false }
                guard !left.isEmpty else { return true }
                return memcmp(left.baseAddress!, right.baseAddress!, left.count) == 0
            }
        }
    }

    static func texts(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { text($0, $1) }
    }

    static func optionalText(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case let (.some(a), .some(b)): text(a, b)
        case (.none, .none): true
        default: false
        }
    }

    static func item(_ a: SchedulerItem, _ b: SchedulerItem) -> Bool {
        text(a.key, b.key) && same(a.value, b.value) && same(a.scope, b.scope)
    }

    static func plan(_ a: SchedulerTracePlan, _ b: SchedulerTracePlan) -> Bool {
        same(a.reference, b.reference) && same(a.payload, b.payload) && same(a.origin, b.origin) &&
            same(a.scope, b.scope) && a.source == b.source &&
            optionalText(a.endpointEvidence.endpointID, b.endpointEvidence.endpointID) &&
            optionalText(a.endpointEvidence.deviceID, b.endpointEvidence.deviceID) &&
            a.endpointEvidence.connectionGeneration == b.endpointEvidence.connectionGeneration &&
            a.endpointEvidence.transportOrigin == b.endpointEvidence.transportOrigin &&
            same(a.capturedEvidence, b.capturedEvidence) && text(a.targetID, b.targetID) &&
            texts(a.affectedElements.sorted(), b.affectedElements.sorted()) &&
            a.classification == b.classification && a.sideEffects == b.sideEffects && a.deliveryMode == b.deliveryMode
    }

    static func authorization(_ a: PlanAuthorization, _ b: PlanAuthorization) -> Bool {
        switch (a, b) {
        case let (.granted(a), .granted(b)): a == b
        case let (.denied(a), .denied(b)): text(a, b)
        default: false
        }
    }

    static func safety(_ a: NativeSafetyResult, _ b: NativeSafetyResult) -> Bool {
        switch (a, b) {
        case (.passed, .passed): true
        case let (.rejected(a), .rejected(b)): text(a, b)
        default: false
        }
    }

    static func result(_ a: FeedbackAttemptResult, _ b: FeedbackAttemptResult) -> Bool {
        switch (a, b) {
        case (.accepted, .accepted): true
        case let (.notAttempted(a), .notAttempted(b)), let (.rejected(a), .rejected(b)): text(a, b)
        default: false
        }
    }

    static func rate(_ a: SchedulerRate, _ b: SchedulerRate) -> Bool {
        switch (a, b) {
        case (.unlimited, .unlimited): true
        case let (.bucket(a, ab, ac), .bucket(b, bb, bc)):
            a.bitPattern == b.bitPattern && ab == bb && ac.bitPattern == bc.bitPattern
        default: false
        }
    }

    static func input(_ a: SchedulerInput, _ b: SchedulerInput) -> Bool {
        switch (a, b) {
        case let (.initialize(a), .initialize(b)): rate(a, b)
        case let (.enqueue(a, ai), .enqueue(b, bi)): item(a, b) && ai == bi
        case let (.cancel(a), .cancel(b)), let (.release(a), .release(b)): text(a, b)
        case let (.drain(a), .drain(b)), let (.failure(a), .failure(b)): a.bitPattern == b.bitPattern
        case (.clear, .clear): true
        case let (.requestDirect(a), .requestDirect(b)): item(a, b)
        case let (.changeStyle(a, ak), .changeStyle(b, bk)): item(a, b) && text(ak, bk)
        case let (.invalidateCache(a), .invalidateCache(b)), let (.refreshDesired(a), .refreshDesired(b)): texts(a, b)
        case let (.gate(a), .gate(b)):
            a.proposalOrdinal == b.proposalOrdinal && item(a.proposedItem, b.proposedItem) &&
                plan(a.dispatchPlan, b.dispatchPlan) && plan(a.proof.plan, b.proof.plan) &&
                same(a.proof.nativeSnapshot, b.proof.nativeSnapshot) &&
                authorization(a.proof.authorization, b.proof.authorization) && safety(a.proof.safety, b.proof.safety) &&
                same(a.currentScope, b.currentScope) && same(a.currentNativeSnapshot, b.currentNativeSnapshot)
        case let (.receipt(a), .receipt(b)):
            item(a.item, b.item) && plan(a.dispatchPlan, b.dispatchPlan) && result(a.result, b.result) &&
                same(a.currentScope, b.currentScope)
        default: false
        }
    }

    static func envelope(_ a: SchedulerEnvelope, _ b: SchedulerEnvelope) -> Bool {
        text(a.owner, b.owner) && a.ordinal == b.ordinal && input(a.input, b.input) && same(a.context, b.context)
    }

    static func identifier(owner: String, ordinal: UInt64) -> Data {
        var data = Data(owner.utf8); data.append(0)
        var value = ordinal.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return data
    }
}

/// Constructed once from the actual input. The same immutable bytes feed cold replay and persistence.
struct J4PreparedInput {
    let envelope: SchedulerEnvelope
    let data: Data
    init(_ envelope: SchedulerEnvelope) throws {
        self.envelope = envelope
        data = try SchedulerTraceCodec.encodeInput(envelope)
    }

    init(_ envelope: SchedulerEnvelope, canonicalData: Data) throws {
        guard try SchedulerTraceCodec.encodeInput(envelope) == canonicalData else {
            throw SchedulerCandidateError.invalid("prepared input/data exact binding")
        }
        self.envelope = envelope
        data = canonicalData
    }

    func validate(_ step: SchedulerStep) throws {
        // Preserve the original assertion, then compare every scalar bit/string byte and ordered field.
        // Data is immutable and constructed/verified from this envelope exactly once at preparation.
        guard step.input == envelope,
              J4ExactJSON.envelope(step.input, envelope)
        else {
            throw SchedulerCandidateError.invalid("prepared input/step exact binding")
        }
    }
}

/// Per-archive exact structural intern keys. Full Data equality resolves every lookup;
/// child IDs are assigned only after their complete byte/bits tuple has matched.
struct J4ExactNodeIndex {
    private var nodes: [Data: UInt64] = [:]
    private mutating func intern(_ key: Data) -> UInt64 {
        if let id = nodes[key] { return id }
        let id = UInt64(nodes.count) + 1
        nodes[key] = id
        return id
    }

    private func append(_ value: UInt64, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func append(_ value: String, to data: inout Data) {
        append(UInt64(value.utf8.count), to: &data)
        data.append(contentsOf: value.utf8)
    }

    mutating func node(_ value: ScenarioPayload) -> UInt64 {
        var key = Data()
        switch value {
        case .scalar(.null): key.append(0)
        case let .scalar(.flag(value)): key.append(1); key.append(value ? 1 : 0)
        case let .scalar(.number(value)): key.append(2); append(value.bitPattern, to: &key)
        case let .scalar(.text(value)): key.append(3); append(value, to: &key)
        case let .array(values):
            key.append(4); append(UInt64(values.count), to: &key)
            for value in values { append(node(value), to: &key) }
        case let .object(values):
            key.append(5); append(UInt64(values.count), to: &key)
            for name in values.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                append(name, to: &key); append(node(values[name]!), to: &key)
            }
        }
        return intern(key)
    }

    mutating func itemKey(_ item: SchedulerItem) -> Data {
        var key = Data([6])
        append(item.key, to: &key)
        append(node(item.value), to: &key); append(node(item.scope), to: &key)
        return key
    }
}
