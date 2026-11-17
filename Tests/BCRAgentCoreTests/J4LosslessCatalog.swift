import Foundation
import SurfaceDeviceConformance
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning

/// Bound Foundation's temporary decoder/encoder autoreleases per input, not per XCTest lifetime.
func j4Pool<Result>(_ operation: () throws -> Result) rethrows -> Result {
    #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: operation)
    #else
        return try operation()
    #endif
}

/// Diagnostic compression only. Runtime candidates still compare complete typed steps.
/// Catalog internment checks complete typed equality; references never become permits/identities.
final class J4LosslessCatalog {
    private let input: FileHandle, output: FileHandle, differences: FileHandle, catalog: FileHandle
    private let encoder: JSONEncoder
    private var next = 0
    private var items: [String: [(SchedulerItem, String)]] = [:]
    private var plans: [String: (SchedulerTracePlan, String)] = [:]
    private var proposals: [String: (SchedulerProposal, String)] = [:]
    private var strings: [String: String] = [:]
    private var states: [String: [String: ScenarioPayload]] = [:]
    private var ordinals: [String: UInt64] = [:]
    private(set) var stepCount = 0, differenceCount = 0, catalogCount = 0
    private let null = ScenarioPayload.scalar(.null)
    private func s(_ value: String) -> ScenarioPayload { .scalar(.text(value)) }
    private func n(_ value: Double) -> ScenarioPayload { .scalar(.number(value)) }
    private func array(_ values: [String]) -> ScenarioPayload { .array(values.map(s)) }
    init(directory: URL, suffix: String) throws {
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func create(_ name: String) throws -> FileHandle {
            let path = directory.appending(path: name + "-" + suffix)
            guard !FileManager.default.fileExists(atPath: path.path), FileManager.default.createFile(
                atPath: path.path,
                contents: nil
            ) else { throw SchedulerCandidateError.invalid("reused catalog output") }
            return try FileHandle(forWritingTo: path)
        }
        input = try create("inputs"); output = try create("candidate-catalog"); differences =
            try create("differences"); catalog = try create("catalog")
    }

    deinit { try? input.close(); try? output.close(); try? differences.close(); try? catalog.close() }
    private func line(_ value: ScenarioPayload, to file: FileHandle) throws {
        var data = try encoder.encode(value); data.append(10); try file.write(contentsOf: data)
    }

    private func intern(_ value: ScenarioPayload, composite: Bool = false) throws -> ScenarioPayload {
        next += 1; let id = "value." + String(next); catalogCount += 1
        try line(.object(["id": s(id), "kind": s(composite ? "composite" : "literal"), "value": value]), to: catalog)
        return .object(["$catalog": s(id)])
    }

    private func reference(_ id: String) -> ScenarioPayload { .object(["$catalog": s(id)]) }
    private func item(_ value: SchedulerItem) throws -> ScenarioPayload {
        if let found = items[value.key]?.first(where: { $0.0 == value }) { return reference(found.1) }
        let ref = try intern(SchedulerTraceCodec.itemPayload(value))
        guard case let .object(raw) = ref,
              case let .scalar(.text(id)) = raw["$catalog"]
        else { throw SchedulerCandidateError.invalid("catalog reference") }
        items[value.key, default: []].append((value, id)); return ref
    }

    private func proposal(_ value: SchedulerProposal, owner: String) throws -> ScenarioPayload {
        let key = owner + ":" + String(value.ordinal)
        if let old = proposals[key] {
            guard old.0 == value
            else { throw SchedulerCandidateError.invalid("conflicting immutable proposal")
            }; return reference(old.1)
        }
        let ref = try intern(
            .object(["ordinal": s(String(value.ordinal)), "cause_ordinal": s(String(value.causeOrdinal)),
                     "cause": s(value.cause.rawValue), "item": item(value.item)]),
            composite: true
        )
        guard case let .object(raw) = ref,
              case let .scalar(.text(id)) = raw["$catalog"]
        else { throw SchedulerCandidateError.invalid("catalog reference") }
        proposals[key] = (value, id); return ref
    }

    private func plan(_ value: SchedulerTracePlan, owner: String, proposalOrdinal: UInt64) throws -> ScenarioPayload {
        let key = owner + ":" + String(proposalOrdinal)
        if let old = plans[key] {
            guard old.0 == value
            else { throw SchedulerCandidateError.invalid("conflicting immutable plan") }; return reference(old.1)
        }
        let ref = try intern(SchedulerTraceCodec.planPayload(value))
        guard case let .object(raw) = ref,
              case let .scalar(.text(id)) = raw["$catalog"]
        else { throw SchedulerCandidateError.invalid("catalog reference") }
        plans[key] = (value, id); return ref
    }

    private func textRef(_ value: String) throws -> ScenarioPayload {
        if let id = strings[value] { return reference(id) }
        let ref = try intern(s(value))
        guard case let .object(raw) = ref,
              case let .scalar(.text(id)) = raw["$catalog"]
        else { throw SchedulerCandidateError.invalid("catalog reference") }
        strings[value] = id; return ref
    }

    private func rate(_ value: SchedulerRate?) -> ScenarioPayload {
        guard let value else { return null }
        switch value {
        case .unlimited: return .object(["kind": s("unlimited")])
        case let .bucket(perSecond, burst, cooldown): return .object([
                "kind": s("bucket"),
                "per_second": n(perSecond),
                "burst": n(Double(burst)),
                "error_cooldown": n(cooldown)
            ])
        }
    }

    private func preflight(_ value: FeedbackPreflight) -> ScenarioPayload {
        if value == .permitted { return .object(["state": s("permitted")]) }
        guard case let .rejected(reason) = value else { return null }
        var data: [String: ScenarioPayload] = ["state": s("rejected")]
        switch reason {
        case .planMismatch: data["reason"] = s("plan_mismatch")
        case .staleScope: data["reason"] = s("stale_scope")
        case .staleNativeProof: data["reason"] = s("stale_native_proof")
        case let .authorizationDenied(reason): data["reason"] = s("authorization_denied"); data["native_reason"] =
            s(reason)
        case let .wrongDirections(missing,
                                  surplus): data["reason"] = s("wrong_directions"); data["missing"] = array(missing.map(
                \.rawValue
            )
            .sorted()); data["surplus"] = array(surplus.map(\.rawValue).sorted())
        case let .nativeRejected(reason): data["reason"] = s("native_rejected"); data["native_reason"] = s(reason)
        }
        return .object(data)
    }

    private func result(_ value: FeedbackAttemptResult) -> ScenarioPayload {
        switch value {
        case .accepted: .object(["state": s("accepted")])
        case let .rejected(reason): .object(["state": s("rejected"), "reason": s(reason)])
        case let .notAttempted(reason): .object(["state": s("not_attempted"), "reason": s(reason)])
        }
    }

    private func delta(_ current: [String: ScenarioPayload], previous: [String: ScenarioPayload]) -> ScenarioPayload {
        var changes: [String: ScenarioPayload] = [:]
        for (key, value) in current where previous[key] != value {
            if case let .array(new) = value, case let .array(old) = previous[key], new.count >= old.count,
               Array(new.prefix(old.count)) == old
            {
                changes[key] = .object(["append": .array(Array(new.dropFirst(old.count)))])
            } else { changes[key] = .object(["replace": value]) }
        }
        return .object(changes)
    }

    func append(_ envelope: SchedulerEnvelope, step: SchedulerStep) throws {
        guard envelope.ordinal == ordinals[envelope.owner, default: 0] + 1,
              step.input == envelope else { throw SchedulerCandidateError.ordinalMismatch }
        ordinals[envelope.owner] = envelope.ordinal
        var data = try SchedulerTraceCodec.encodeInput(envelope); data.append(10); try input.write(contentsOf: data)
        let snapshot = step.snapshot, owner = envelope.owner
        let state: [String: ScenarioPayload] = [
            "owner": snapshot.owner.map(s) ?? null, "input_ordinal": s(String(snapshot.inputOrdinal)),
            "rate": rate(snapshot.rate),
            "queued": .array(try snapshot.queued.map(item)), "withheld": .array(try snapshot.withheld.map(item)),
            "desired": .object(try snapshot.desired.mapValues(item)),
            "accepted_cache": .object(try snapshot.acceptedCache.mapValues(item)),
            "awaiting_gate": .array(try snapshot.awaitingGate.map { try proposal($0, owner: owner) }),
            "awaiting_receipt": .array(try snapshot.awaitingReceipt.map { .object([
                "proposal": try proposal($0.proposal, owner: owner),
                "plan": try plan($0.plan, owner: owner, proposalOrdinal: $0.proposal.ordinal)
            ]) }),
            "tokens": snapshot.tokens.map(n) ?? null, "last_refill": snapshot.lastRefill.map(n) ?? null,
            "retry_after": snapshot.retryAfter.map(n) ?? null,
            "persistent_alignment_differences": .array(try snapshot.persistentAlignmentDifferences.map(textRef))
        ]
        let previous = states[owner] ?? [:]; states[owner] = state
        let receipts: [ScenarioPayload] = try step.receipts.map { association in
            // Unmatched actual receipts have no candidate proposal ordinal. Catalog them as whole
            // immutable native outcome values, without claiming or manufacturing a candidate plan.
            let planRef: ScenarioPayload = if let ordinal = association.proposalOrdinal {
                try plan(association.receipt.dispatchPlan, owner: owner, proposalOrdinal: ordinal)
            } else { try intern(SchedulerTraceCodec.planPayload(association.receipt.dispatchPlan)) }
            return .object(["proposal": association.proposalOrdinal.map { s(String($0)) } ?? null,
                            "item": try item(association.receipt.item), "plan": planRef,
                            "result": result(association.receipt.result),
                            "current_scope_matches": association.currentScopeMatches
                                .map { .scalar(.flag($0)) } ?? null])
        }
        try line(
            .object([
                "artifact": s("scheduler_candidate_catalog_output_v1"),
                "owner": s(owner),
                "ordinal": s(String(envelope.ordinal)),
                "state_delta": delta(state, previous: previous),
                "proposals": .array(try step.proposals.map { try proposal($0, owner: owner) }),
                "removed_keys": array(step.removedKeys),
                "replaced_keys": array(step.replacedKeys),
                "deduplicated_keys": array(step.deduplicatedKeys),
                "gates": .array(step.gateDecisions.map { .object([
                    "proposal": s(String($0.proposalOrdinal)),
                    "result": preflight($0.result)
                ]) }),
                "receipts": .array(receipts),
                "alignment_differences": .array(try step.alignmentDifferences.map(textRef))
            ]),
            to: output
        )
        stepCount += 1
    }

    func difference(_ value: ScenarioPayload) throws { try line(value, to: differences); differenceCount += 1 }
}

/// Exact diagnostic expansion. Reject missing/duplicate/conflicting catalog IDs and cursor gaps.
struct J4CatalogExpander {
    private var values: [String: (ScenarioPayload, Bool)] = [:]
    private var states: [String: [String: ScenarioPayload]] = [:]
    private var ordinals: [String: UInt64] = [:]
    private let null = ScenarioPayload.scalar(.null)
    private func object(_ value: ScenarioPayload) throws
        -> [String: ScenarioPayload]
    { guard case let .object(value) = value
        else { throw SchedulerCandidateError.invalid("catalog object") }; return value
    }

    private func text(_ value: ScenarioPayload?) throws -> String { guard case let .scalar(.text(value)) = value
        else { throw SchedulerCandidateError.invalid("catalog text") }; return value
    }

    mutating func add(_ row: ScenarioPayload) throws {
        let row = try object(row); guard Set(row.keys) == ["id", "kind", "value"]
        else { throw SchedulerCandidateError.invalid("catalog fields") }
        let id = try text(row["id"])
        guard values[id] == nil else { throw SchedulerCandidateError.invalid("duplicate/conflicting catalog") }
        let kind = try text(row["kind"])
        guard kind == "literal" || kind == "composite" else { throw SchedulerCandidateError.invalid("catalog kind") }
        values[id] = (row["value"]!, kind == "composite")
    }

    private func expand(_ value: ScenarioPayload, active: Set<String> = []) throws -> ScenarioPayload {
        switch value {
        case let .object(raw):
            if Set(raw.keys) == ["$catalog"] {
                let id = try text(raw["$catalog"]); guard let value = values[id],
                                                          !active.contains(id)
                else {
                    throw SchedulerCandidateError
                        .invalid("missing/cyclic catalog " + id)
                }
                return value.1 ? try expand(value.0, active: active.union([id])) : value.0
            }
            return .object(try raw.mapValues { try expand($0, active: active) })
        case let .array(raw): return .array(try raw.map { try expand($0, active: active) })
        default: return value
        }
    }

    mutating func step(_ row: ScenarioPayload, input: SchedulerEnvelope) throws -> ScenarioPayload {
        let row = try object(row), owner = try text(row["owner"]), rawOrdinal = try text(row["ordinal"])
        guard let ordinal = UInt64(rawOrdinal), String(ordinal) == rawOrdinal,
              ordinal == ordinals[owner, default: 0] + 1,
              owner == input.owner, ordinal == input.ordinal,
              row["artifact"] == .scalar(.text("scheduler_candidate_catalog_output_v1")),
              Set(row.keys) == [
                  "artifact",
                  "owner",
                  "ordinal",
                  "state_delta",
                  "proposals",
                  "removed_keys",
                  "replaced_keys",
                  "deduplicated_keys",
                  "gates",
                  "receipts",
                  "alignment_differences"
              ] else { throw SchedulerCandidateError.ordinalMismatch }
        var state = states[owner] ?? [:]
        for (key, patch) in try object(row["state_delta"]!) {
            let patch = try object(patch)
            if Set(patch.keys) == ["replace"] { state[key] = patch["replace"]! }
            else if Set(patch.keys) == ["append"], case let .array(suffix) = patch["append"],
                    case let .array(prefix) = state[key] { state[key] = .array(prefix + suffix) }
            else { throw SchedulerCandidateError.invalid("state delta") }
        }
        let fields: Set<String> = [
            "owner",
            "input_ordinal",
            "rate",
            "queued",
            "withheld",
            "desired",
            "accepted_cache",
            "awaiting_gate",
            "awaiting_receipt",
            "tokens",
            "last_refill",
            "retry_after",
            "persistent_alignment_differences"
        ]
        guard Set(state.keys) == fields, state["owner"] == .scalar(.text(owner)),
              state["input_ordinal"] == .scalar(.text(rawOrdinal))
        else { throw SchedulerCandidateError.invalid("missing complete state field/ordinal") }
        states[owner] = state; ordinals[owner] = ordinal
        var complete: [String: ScenarioPayload] = ["artifact": .scalar(.text("scheduler_candidate_output_v1")),
                                                   "input": try JSONDecoder().decode(
                                                       ScenarioPayload.self,
                                                       from: SchedulerTraceCodec.encodeInput(input)
                                                   ), "state": .object(state)]
        for key in [
            "proposals",
            "removed_keys",
            "replaced_keys",
            "deduplicated_keys",
            "gates",
            "receipts",
            "alignment_differences"
        ] { complete[key] = row[key]! }
        let originalInput = complete.removeValue(forKey: "input")!
        guard case var .object(expanded) = try expand(.object(complete))
        else { throw SchedulerCandidateError.invalid("expanded output") }
        expanded["input"] = originalInput // Opaque native data may itself contain a literal "$catalog" key.
        return .object(expanded)
    }
}
