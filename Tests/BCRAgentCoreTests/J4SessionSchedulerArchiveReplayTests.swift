#if os(Linux)
    import Glibc
#else
    import Darwin
#endif
import Foundation
import Dispatch
import XCTest
import BCRFoundation
@testable import BCRSurfaceDomain
import SurfaceDeviceConformance
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning

private enum J4P {
    static let null = ScenarioPayload.scalar(.null)
    static func s(_ value: String) -> ScenarioPayload { .scalar(.text(value)) }
    static func object(_ value: ScenarioPayload) throws -> [String: ScenarioPayload] {
        guard case let .object(value) = value else { throw SchedulerCandidateError.invalid("object") }; return value
    }

    static func text(_ value: ScenarioPayload?) throws -> String {
        guard case let .scalar(.text(value)) = value
        else { throw SchedulerCandidateError.invalid("text") }; return value
    }

    static func number(_ value: ScenarioPayload?) throws -> Double {
        guard case let .scalar(.number(value)) = value,
              value.isFinite else { throw SchedulerCandidateError.invalid("finite number") }; return value
    }

    static func bool(_ value: ScenarioPayload?) throws -> Bool {
        guard case let .scalar(.flag(value)) = value
        else { throw SchedulerCandidateError.invalid("bool") }; return value
    }

    static func nullable(_ value: ScenarioPayload?) throws -> ScenarioPayload? {
        guard let value
        else { throw SchedulerCandidateError.invalid("missing nullable") }; return value == null ? nil : value
    }

    static func uint(_ value: ScenarioPayload?) throws -> UInt64 {
        let raw = try text(value); guard let value = UInt64(raw),
                                         String(value) == raw
        else { throw SchedulerCandidateError.invalid("decimal") }; return value
    }

    static func data(_ value: ScenarioPayload) throws -> Data { let e = JSONEncoder(); e
        .outputFormatting = [.sortedKeys]; return try e.encode(value)
    }

    static func any(_ value: Any) throws -> ScenarioPayload { try J4PayloadCodec.any(value) }
    static func ref(_ value: ScenarioPayload?) throws -> String? {
        guard let present = try nullable(value) else { return nil }; let fields = try object(present)
        return try text(fields["owner"]) + ":" + String(uint(fields["ordinal"]))
    }

    static func key(_ message: MIDIVoiceMessage) -> String { FeedbackJ4Trace.key(message.controlID) }
    static func message(_ item: SchedulerItem) throws -> MIDIVoiceMessage {
        let value = try object(item.value), message = try object(value["message"]!)
        let channel = try self.number(message["channel"]), address = try self.number(message["number"]),
            amount = try self.number(message["value"])
        guard let ch = UInt8(exactly: channel), let nr = UInt16(exactly: address), let val = UInt16(exactly: amount),
              ch < 16 else { throw SchedulerCandidateError.invalid("message integer") }
        switch try text(message["case"]) {
        case "nrpn": return .nrpn(channel: ch, number: nr, value: val)
        case "controlChange": guard nr < 128,
                                    val < 256
            else { throw SchedulerCandidateError.invalid("CC") }; return .controlChange(
                channel: ch,
                number: UInt8(nr),
                value: UInt8(val)
            )
        case "noteOn": guard nr < 128, val < 256 else { throw SchedulerCandidateError.invalid("note") }; return .noteOn(
                channel: ch,
                number: UInt8(nr),
                velocity: UInt8(val)
            )
        case "noteOff": guard nr < 128,
                              val < 256 else { throw SchedulerCandidateError.invalid("note") }; return .noteOff(
                channel: ch,
                number: UInt8(nr),
                velocity: UInt8(val)
            )
        default: throw SchedulerCandidateError.invalid("message case")
        }
    }

    static func endpoint(_ value: ScenarioPayload?) throws -> MIDIEndpointSource? {
        guard let present = try nullable(value) else { return nil }; let raw = try object(present)
        guard let provenance = MIDIEndpointProvenance(rawValue: try text(raw["provenance"]))
        else { throw SchedulerCandidateError.invalid("provenance") }
        return .init(
            endpointID: try text(raw["endpoint_id"]),
            deviceID: try nullable(raw["device_id"]).map { try text($0) },
            connectionGeneration: try uint(raw["connection_generation"]),
            provenance: provenance
        )
    }

    static func semanticScope(_ evidence: ScenarioPayload) throws -> ScenarioPayload {
        let evidence = try object(evidence), context = try object(evidence["context"]!)
        guard let source = BCRSurfaceDomain.DeviceSource(rawValue: try text(evidence["source"]))
        else { throw SchedulerCandidateError.invalid("source") }
        let scope = BCRKernelProjection.scope(source: source, generation: try text(context["generation"]),
                                              mapping: try uint(context["mapping_generation"]),
                                              endpoint: try endpoint(evidence["endpoint"]))
        return try any(FeedbackRuntime.value(scope))
    }

    static func queueItem(_ value: ScenarioPayload) throws -> SchedulerItem {
        let raw = try object(value), message = raw["message"]!
        let messageItem = try SchedulerItem(key: "decode-only", value: .object(["message": message]), scope: null)
        let key = try key(self.message(messageItem))
        var scope = raw; scope.removeValue(forKey: "message")
        return try .init(key: key, value: value, scope: .object(scope))
    }
}

private final class J4ReplayTiming {
    private(set) var seconds: [String: Double] = [:]
    private(set) var cpuSeconds: [String: Double] = [:]
    private let includeChildren: Bool
    init(includeChildren: Bool = false) { self.includeChildren = includeChildren }
    private func childCPU() -> Double {
        guard includeChildren else { return 0 }
        var usage = rusage()
        #if os(Linux)
            let who = Int32(RUSAGE_CHILDREN.rawValue)
        #else
            let who = RUSAGE_CHILDREN
        #endif
        precondition(getrusage(who, &usage) == 0, "Cannot observe validator child CPU")
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    func measure<T>(_ name: String, _ operation: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let cpuStart = clock(), childStart = childCPU()
        defer {
            seconds[name, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            cpuSeconds[name, default: 0] += Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC) + childCPU() -
                childStart
        }
        return try operation()
    }
}

private struct J4Admission {
    let session: String
    let owner: String
    let actualItem: SchedulerItem
    let proposal: SchedulerProposal?
    let entry: [String: ScenarioPayload]
    var gateEnvironment: [String: ScenarioPayload]?
    var candidatePermitted: Bool?
    var missingProposalEvidence: ScenarioPayload?
}

/// Test-only independent candidate driver. It never reads session-native/scheduler-native while evolving.
private final class J4SessionReplay {
    var candidates: [String: SchedulerCandidate] = [:]
    private var coldCandidates: [String: SchedulerCandidate] = [:]
    private(set) var coldSteps = 0
    var ordinals: [String: UInt64] = [:]
    var sourceDrainOrdinals: [String: UInt64] = [:]
    var intents: [String: (owner: String, item: SchedulerItem, queued: Bool, proposals: [SchedulerProposal])] = [:]
    var available: [String: [SchedulerProposal]] = [:]
    var admissions: [String: J4Admission] = [:]
    var environmentEntries: [String: String] = [:]
    let archive: J4LosslessCatalog
    let timing = J4ReplayTiming()
    private(set) var inputCount = 0
    init(archive: J4LosslessCatalog) { self.archive = archive }
    var gates = 0, receipts = 0, direct = 0, queued = 0
    var queueComparisons: [String: ScenarioPayload] = [:]
    var policyCauses: [String: [ScenarioPayload]] = [:]
    var queuePolicyCauses: [String: [ScenarioPayload]] = [:]
    func recordPolicyCause(owner: String, kind: String, source: String) {
        policyCauses[owner, default: []].append(.object([
            "kind": J4P.s(kind),
            "original_input_reference": J4P.s(source),
            "candidate_input_ordinal": J4P.s(String(ordinals[owner, default: 0]))
        ]))
    }

    var sessionOwners: Set<String> = []
    private var cacheReceiptReferences: [String: [String: ScenarioPayload]] = [:]
    static func exactCacheDedupEvidence(item: SchedulerItem, cache: [String: SchedulerItem],
                                        receipt: ScenarioPayload?) throws -> ScenarioPayload
    {
        guard cache[item.key] == item,
              let receipt
        else {
            throw SchedulerCandidateError.invalid("absent own proposal has no exact accepted-cache causal evidence")
        }
        return .object(["whole_cached_item": SchedulerTraceCodec.itemPayload(item), "accepted_receipt_input": receipt])
    }

    private func projection(_ step: SchedulerStep) -> ScenarioPayload {
        .object(["pending": .array(step.snapshot.queued.map(SchedulerTraceCodec.itemPayload)),
                 "drained": .array(step.proposals.filter { $0.cause == .drain }
                     .map { SchedulerTraceCodec.itemPayload($0.item) }),
                 "tokens": step.snapshot.tokens.map { .scalar(.number($0)) } ?? J4P.null,
                 "refill": step.snapshot.lastRefill.map { .scalar(.number($0)) } ?? J4P.null,
                 "retry": step.snapshot.retryAfter.map { .scalar(.number($0)) } ?? J4P.null,
                 "removed_keys": .array(step.removedKeys.map(J4P.s)),
                 "replaced_keys": .array(step.replacedKeys.map(J4P.s))])
    }

    func difference(_ kind: String, _ facts: [String: ScenarioPayload]) throws {
        var value = facts; value["classification"] = J4P.s(kind); try archive.difference(.object(value))
    }

    @discardableResult
    func apply(owner: String, _ input: SchedulerInput, context: ScenarioPayload) throws -> SchedulerStep {
        let ordinal = ordinals[owner, default: 0] + 1
        let envelope = SchedulerEnvelope(owner: owner, ordinal: ordinal, input: input, context: context)
        let prepared = try timing.measure("canonical_input_encode") { try J4PreparedInput(envelope) }
        let bytes = prepared.data
        var candidate = candidates[owner] ?? SchedulerCandidate()
        let step = try timing.measure("current_candidate_apply") { try candidate.apply(envelope) }
        // Fresh independent reducer gets only canonical input bytes, never the first state/output.
        var cold = coldCandidates[owner] ?? SchedulerCandidate()
        let decoded = try timing.measure("cold_canonical_input_decode") { try J4PayloadCodec.envelope(bytes) }
        let repeated = try timing.measure("cold_candidate_apply") { try cold.apply(decoded) }
        guard timing.measure("complete_typed_step_compare", { repeated == step })
        else { throw SchedulerCandidateError.invalid("input-only cold replay not reproduced") }
        coldCandidates[owner] = cold; coldSteps += 1
        candidates[owner] = candidate; ordinals[owner] = ordinal
        try timing
            .measure("lossless_catalog_encode_write") { try archive.append(prepared, step: step) }; inputCount += 1
        return step
    }

    func ensureDirect(_ session: String) throws -> String {
        let owner = session + "|direct-unconfigured"
        if candidates[owner] == nil { try apply(
            owner: owner,
            .initialize(.unlimited),
            context: .object(["declared_policy": J4P.s("direct bypass, no native scheduler")])
        ) }
        return owner
    }

    func scheduler(_ event: SchedulerEnvelope) throws {
        let context = try J4P.object(event.context)
        if case .enqueue = event.input, let parent = context["parent_intent"], parent != J4P.null {
            let reference = try J4P.ref(parent)!
            guard let intent = intents[reference],
                  intent.queued
            else { throw SchedulerCandidateError.invalid("missing original generation for derived enqueue") }
            if case let .enqueue(item, _) = event.input,
               item != intent.item { throw SchedulerCandidateError.itemMismatch }
            guard let state = candidates[intent.owner]?.snapshot else { throw SchedulerCandidateError.notInitialized }
            let pending: ScenarioPayload = .array(state.queued.map(SchedulerTraceCodec.itemPayload))
            // Replacement/removal comes from the candidate's original generation step, stored below.
            if var prior = queueComparisons["intent:" + reference].flatMap({ try? J4P.object($0) }) {
                prior["pending"] = pending; queueComparisons[event.owner + ":" + String(event.ordinal)] = .object(prior)
                queuePolicyCauses[event.owner + ":" + String(event.ordinal)] = policyCauses[intent.owner, default: []]
            } else { throw SchedulerCandidateError.invalid("missing candidate generation projection") }
            return // Already applied its original generation intent once, never seed/double-enqueue from native mutation.
        }
        var input = event.input
        if case let .enqueue(item, .derivedCallerRequeue(cause)) = input {
            guard let translated = sourceDrainOrdinals[event.owner + ":" + String(cause)]
            else { throw SchedulerCandidateError.invalid("requeue cause") }
            input = .enqueue(item, ingress: .derivedCallerRequeue(causeOrdinal: translated))
            recordPolicyCause(
                owner: event.owner,
                kind: "caller_failure_requeue_retains_old_proposal_occurrences",
                source: event.owner + ":" + String(event.ordinal)
            )
        }
        let step = try apply(owner: event.owner, input, context: event.context)
        queueComparisons[event.owner + ":" + String(event.ordinal)] = projection(step)
        if !step.deduplicatedKeys.isEmpty { recordPolicyCause(
            owner: event.owner,
            kind: "accepted_receipt_dedup",
            source: event.owner + ":" + String(event.ordinal)
        ) }
        queuePolicyCauses[event.owner + ":" + String(event.ordinal)] = policyCauses[event.owner, default: []]
        if case .drain = input {
            sourceDrainOrdinals[event.owner + ":" + String(event.ordinal)] = step.input.ordinal
            available[event.owner, default: []] += step.proposals
        }
    }

    func producerItem(_ args: [String: ScenarioPayload], queued: Bool) throws -> SchedulerItem {
        let evidence = try J4P.object(args["evidence"]!), context = try J4P.object(evidence["context"]!)
        if queued {
            let scope: ScenarioPayload = .object(["origin": args["origin"]!, "source": evidence["source"]!,
                                                  "endpoint": evidence["endpoint"]!,
                                                  "mapping_revision": context["mapping_generation"]!,
                                                  "context": .object([
                                                      "generation": context["generation"]!,
                                                      "mapping_generation": context["mapping_generation"]!,
                                                      "known_device_context_id": J4P.null
                                                  ])])
            var value = try J4P.object(scope); value["message"] = args["message"]!
            return try J4P.queueItem(.object(value))
        }
        let direct: ScenarioPayload = .object(["message": args["message"]!, "origin": args["origin"]!,
                                               "resolved_timing": args["resolved_timing"]!,
                                               "evidence": args["evidence"]!])
        let prototype = try SchedulerItem(key: "decode-only", value: direct, scope: J4P.null)
        return try .init(
            key: J4P.key(J4P.message(prototype)),
            value: direct,
            scope: J4P.semanticScope(args["evidence"]!)
        )
    }

    func session(_ raw: ScenarioPayload) throws {
        let row = try J4P.object(raw), session = try J4P.text(row["owner"]), ordinal = try J4P.uint(row["ordinal"])
        let reference = session + ":" + String(ordinal), operation = try J4P.text(row["operation"]),
            args = try J4P.object(row["arguments"]!)
        switch operation {
        case "attach_scheduler": sessionOwners
            .insert(try J4P.text(args["scheduler_owner"])) // Actual initialize already occurred.
        case "clear_queue":
            if args["scheduler_owner"] == J4P.null { let owner = try ensureDirect(session); try apply(
                owner: owner,
                .clear,
                context: raw
            ) }
        case "message_intent":
            let routing = try J4P.object(args["routing_facts"]!), policy = try J4P.object(routing["feedback_policy"]!)
            let isQueued = try J4P.text(routing["source"]) == "hardware" && J4P
                .bool(policy["enabled"]) && routing["connected_destination"] != J4P.null && J4P
                .text(args["resolved_timing"]) == "coalesced"
            let owner = try J4P.nullable(args["scheduler_owner"]).map { try J4P.text($0) } ?? ensureDirect(session)
            let item = try producerItem(args, queued: isQueued)
            let step = try apply(
                owner: owner,
                isQueued ? .enqueue(item, ingress: .externalRequest) : .requestDirect(item),
                context: raw
            )
            intents[reference] = (owner, item, isQueued, step.proposals)
            queueComparisons["intent:" + reference] = projection(step)
            sessionOwners.insert(owner)
            if !step.deduplicatedKeys.isEmpty { recordPolicyCause(
                owner: owner,
                kind: "accepted_receipt_dedup",
                source: reference
            ) }
            let policyEvidence = try J4P.object(args["evidence"]!)
            if try J4P.text(policyEvidence["source"]) == "hardware",
               try J4P.text(policyEvidence["hardware_output"]) == "observe"
            {
                recordPolicyCause(
                    owner: owner,
                    kind: "native_observe_withdrawal_vs_candidate_retained_intent",
                    source: reference
                )
            }
            if isQueued { queued += 1 } else { direct += 1 }
            let producerEvidence = try J4P.object(args["evidence"]!)
            if !isQueued, try J4P.text(producerEvidence["source"]) == "hardware",
               try J4P.text(producerEvidence["hardware_output"]) == "observe", let proposal = step.proposals.first
            {
                let declared: [String: ScenarioPayload] = [
                    "captured_evidence": args["evidence"]!,
                    "current_evidence": args["evidence"]!,
                    "hardware_map": args["hardware_map"]!,
                    "device_connection": .object([
                        "state": J4P.s("not_run"),
                        "reason": J4P.s("generation observe policy rejected before device getter")
                    ])
                ]
                guard let query = try gate(
                    item: proposal.item,
                    proposal: proposal.ordinal,
                    entry: declared,
                    fresh: declared
                ) else { throw SchedulerCandidateError.invalid("missing own observe rejection") }
                try apply(owner: owner, .gate(query), context: raw); gates += 1
            }
        case "dispatch_environment":
            let phase = try J4P.text(args["phase"])
            if phase == "entry" {
                let parent = try J4P.ref(args["parent_intent"])
                let owner: String, actual: SchedulerItem, proposal: SchedulerProposal?
                if let parent, let intent = intents[parent] {
                    owner = intent.owner; actual = intent.item; proposal = intent.proposals.first
                } else {
                    guard let origin = try J4P.nullable(args["origin_scheduler_owner"])
                    else { throw SchedulerCandidateError.invalid("missing queue origin owner") }
                    owner = try J4P.text(origin)
                    let evidence = try J4P.object(args["captured_evidence"]!)
                    guard let nativeQueued = try J4P.nullable(evidence["legacy_queued"])
                    else { throw SchedulerCandidateError.invalid("missing whole legacy queue item") }
                    actual = try J4P.queueItem(nativeQueued)
                    proposal = available[owner]?.isEmpty == false ? available[owner]!.removeFirst() : nil
                }
                var missingEvidence: ScenarioPayload?
                if proposal == nil {
                    // Absence alone is never called alignment: prove the whole own cached item and its matched, current accepted receipt.
                    missingEvidence = try Self.exactCacheDedupEvidence(
                        item: actual,
                        cache: candidates[owner]?.snapshot.acceptedCache ?? [:],
                        receipt: cacheReceiptReferences[owner]?[actual.key]
                    )
                    try difference(
                        "exact_accepted_cache_dedup",
                        [
                            "entry": J4P.s(reference),
                            "actual": SchedulerTraceCodec.itemPayload(actual),
                            "cause": missingEvidence!
                        ]
                    )
                }
                admissions[reference] = .init(
                    session: session,
                    owner: owner,
                    actualItem: actual,
                    proposal: proposal,
                    entry: args,
                    missingProposalEvidence: missingEvidence
                )
                if let proposal, proposal.item != actual { try difference(
                    "ordered_proposal_payload_alignment",
                    [
                        "entry": J4P.s(reference),
                        "own": SchedulerTraceCodec.itemPayload(proposal.item),
                        "actual": SchedulerTraceCodec.itemPayload(actual)
                    ]
                ) }
            } else {
                guard let entry = try J4P.ref(args["entry"]),
                      var admission = admissions[entry]
                else { throw SchedulerCandidateError.invalid("environment entry association") }
                admission.gateEnvironment = args; environmentEntries[reference] = entry
                if let proposal = admission.proposal {
                    if let query = try gate(
                        item: proposal.item,
                        proposal: proposal.ordinal,
                        entry: admission.entry,
                        fresh: args
                    ) {
                        let step = try apply(owner: admission.owner, .gate(query), context: raw)
                        admission.candidatePermitted = step.gateDecisions.first?.result == .permitted; gates += 1
                        if admission
                            .candidatePermitted ==
                            false
                        {
                            recordPolicyCause(
                                owner: admission.owner,
                                kind: "candidate_retains_rejected_intent",
                                source: reference
                            )
                        }
                    } else {
                        if proposal.item == admission
                            .actualItem
                        {
                            throw SchedulerCandidateError.invalid("matching own item has no reached native snapshot")
                        }
                        try difference(
                            "fresh_native_fact_unexecuted_after_policy_divergence",
                            ["entry": J4P.s(entry), "own": SchedulerTraceCodec.itemPayload(proposal.item)]
                        )
                    }
                }
                admissions[entry] = admission
            }
        case "actual_boundary_result":
            guard let entry = try J4P.ref(args["entry"]), let admission = admissions[entry],
                  let fresh = admission.gateEnvironment
            else { throw SchedulerCandidateError.invalid("receipt entry/environment association") }
            guard try J4P.bool(args["entered"])
            else { throw SchedulerCandidateError.invalid("nonattempt is not an actual admission completion") }
            let actualPlan = try makePlan(item: admission.actualItem, entry: admission.entry)
            let actualResult = try J4P.object(args["result"]!), outcome: FeedbackAttemptResult
            switch try J4P.text(actualResult["state"]) {
            case "accepted": outcome = .accepted
            case "rejected": outcome = .rejected(reason: try J4P.text(actualResult["reason"]))
            default: throw SchedulerCandidateError.invalid("actual outcome")
            }
            let receipt = SchedulerActualReceipt(item: admission.actualItem, dispatchPlan: actualPlan, result: outcome,
                                                 currentScope: args["current_scope_at_original_bookkeeping"]!)
            let step = try apply(owner: admission.owner, .receipt(receipt), context: raw); receipts += 1
            if admission.proposal?.item == admission.actualItem, admission.candidatePermitted == true,
               step.receipts.first?
                   .proposalOrdinal ==
                   nil { throw SchedulerCandidateError.invalid("matching actual receipt failed full binding") }
            if admission.candidatePermitted == false, admission.proposal?.item == admission.actualItem {
                throw SchedulerCandidateError.invalid("own fresh gate rejected identical actual attempted item")
            }
            if let association = step.receipts.first, association.proposalOrdinal != nil,
               association.currentScopeMatches == true, outcome == .accepted
            {
                cacheReceiptReferences[admission.owner, default: [:]][admission.actualItem.key] = .object([
                    "candidate_owner": J4P.s(admission.owner),
                    "candidate_input_ordinal": J4P.s(String(step.input.ordinal)), "original_input": raw
                ])
            }
            if !step.alignmentDifferences.isEmpty {
                let cause: ScenarioPayload
                if let evidence = admission.missingProposalEvidence { cause = evidence }
                else if let proposal = admission.proposal, proposal.item != admission.actualItem {
                    cause = .object([
                        "own_ordered_proposal": SchedulerTraceCodec.itemPayload(proposal.item),
                        "actual_item": SchedulerTraceCodec.itemPayload(admission.actualItem)
                    ])
                } else {
                    throw SchedulerCandidateError
                        .invalid("unmatched receipt without exact dedup or ordered proposal divergence")
                }
                try difference(
                    "receipt_alignment_after_proven_policy_divergence",
                    ["entry": J4P.s(entry), "cause": cause, "messages": .array(step.alignmentDifferences.map(J4P.s))]
                )
            }
            _ = fresh // Retained in the original input and canonical gate; never a native-allowed oracle.
        case "admission_completed":
            guard let entry = try J4P.ref(args["entry"]),
                  let admission = admissions.removeValue(forKey: entry)
            else { throw SchedulerCandidateError.invalid("missing admission completion") }
            if admission.proposal != nil,
               admission
                   .gateEnvironment ==
                   nil { throw SchedulerCandidateError.invalid("missing reached native gate environment") }
        default: throw SchedulerCandidateError.invalid("unknown session input")
        }
    }

    private func adjusted(_ raw: ScenarioPayload, item: SchedulerItem) throws -> ScenarioPayload {
        var evidence = try J4P.object(raw), value = try J4P.object(item.value)
        if let ownDirect = value["evidence"] {
            let direct = try J4P.object(ownDirect)
            evidence["legacy_queued"] = J4P.null
            for key in [
                "expected_endpoint",
                "expected_mapping",
                "receipt_identity",
                "accepted_hook_present",
                "resolved_generation_timing"
            ] { evidence[key] = direct[key]! }
        } else {
            evidence["legacy_queued"] = item.value; evidence["expected_endpoint"] = value["endpoint"]!
            evidence["expected_mapping"] = value["mapping_revision"]!; evidence["receipt_identity"] = J4P.null
            evidence["accepted_hook_present"] = .scalar(.flag(false)); evidence["resolved_generation_timing"] = J4P.null
        }
        return .object(evidence)
    }

    private func makePlan(item: SchedulerItem, entry: [String: ScenarioPayload]) throws -> SchedulerTracePlan {
        let raw = try adjusted(entry["captured_evidence"]!, item: item), evidence = try J4P.object(raw)
        let message = try J4P.message(item)
        let map = try JSONDecoder().decode(HardwareMap.self, from: J4P.data(entry["hardware_map"]!))
        let control = map.control(for: message.controlID)
        let endpoint = try BCRNeutralSurfaceProjection.endpoint(J4P.endpoint(evidence["endpoint"]))
        let source: SurfaceDeviceContracts.DeviceSource = try J4P
            .text(evidence["source"]) == "mock" ? .simulation : .hardware
        let origin = try J4P.object(item.value)["origin"]!
        return try .init(
            reference: J4P.s(item.key),
            payload: item.value,
            origin: origin,
            scope: J4P.semanticScope(raw),
            source: source,
            endpointEvidence: endpoint,
            capturedEvidence: SchedulerTraceCodec.queuedEvidence(for: item, nativeDispatch: raw),
            targetID: control.map(BCRNeutralSurfaceProjection.logicalTargetID) ?? ("midi." + item.key),
            affectedElements: Set(control.map { [BCRNeutralSurfaceProjection.elementID($0)] } ?? []),
            classification: .display,
            sideEffects: [],
            deliveryMode: .direct
        )
    }

    private func gate(
        item: SchedulerItem,
        proposal: UInt64,
        entry: [String: ScenarioPayload],
        fresh: [String: ScenarioPayload]
    ) throws -> SchedulerGateRecord? {
        let plan = try makePlan(item: item, entry: entry)
        let captured = try adjusted(entry["captured_evidence"]!, item: item), evidence = try J4P.object(captured)
        let current = try adjusted(fresh["current_evidence"]!, item: item), now = try J4P.object(current)
        var authorization: PlanAuthorization = .denied(reason: "unexecuted_authorization")
        var safety: NativeSafetyResult = .rejected(reason: "unexecuted_device_filter")
        let source = try J4P.text(now["source"])
        let expectedEndpoint = try J4P.nullable(evidence["expected_endpoint"]),
            expectedMapping = try J4P.nullable(evidence["expected_mapping"])
        if source == "hardware",
           try J4P.text(evidence["hardware_output"]) == "observe" { authorization = .denied(reason: "observe") }
        else if source == "hardware",
                now["publication_revision"] != J4P.null { safety = .rejected(reason: "unpublished_connection") }
        else if let expectedEndpoint,
                expectedEndpoint != now["endpoint"]! { safety = .rejected(reason: "expected_endpoint") }
        else {
            if let permission = try J4P.nullable(evidence["parameter_context"]) {
                let permission = try J4P.object(permission), context = try J4P.object(now["context"]!)
                let valid = try permission["source"] == now["source"] && permission["generation"] ==
                    context["generation"] && permission["mapping_revision"] == context["mapping_generation"] && J4P
                    .bool(permission["allows_display"])
                authorization = valid ? .granted(directions: [.display]) : .denied(reason: "parameter_context")
            } else { authorization = .granted(directions: [.display]) }
            if case .granted = authorization {
                let context = try J4P.object(now["context"]!)
                if let expectedMapping,
                   expectedMapping != context["mapping_generation"]! { safety = .rejected(reason: "expected_mapping") }
                else {
                    let device = try J4P.object(fresh["device_connection"]!)
                    guard try J4P.text(device["state"]) == "read" else { return nil }
                    let value = try J4P.object(device["value"]!)
                    safety = value["output_name"] == J4P.null ? .rejected(reason: "disconnected") : .passed
                }
            }
        }
        let device = fresh["device_connection"]!
        let nativeSnapshot: ScenarioPayload = .object(["evidence": captured, "device_connection": device])
        let currentSnapshot: ScenarioPayload = .object(["evidence": current, "device_connection": device])
        return .init(proposalOrdinal: proposal, proposedItem: item, dispatchPlan: plan,
                     proof: .init(
                         plan: plan,
                         nativeSnapshot: nativeSnapshot,
                         authorization: authorization,
                         safety: safety
                     ),
                     currentScope: try J4P.semanticScope(current), currentNativeSnapshot: currentSnapshot)
    }
}

final class J4SessionSchedulerArchiveReplayTests: XCTestCase {
    private func validateOriginalSources(_ file: URL, outputs: Bool) throws -> [String: Any] {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let validator = Process(), diagnostics = Pipe()
        validator.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        validator.arguments = ["python3", repository.appending(path: "configs/j4_shadow_verification.py").path,
                               outputs ? "--validate-process-outputs" : "--validate-process-inputs", file.path]
        validator.currentDirectoryURL = repository
        validator.standardOutput = diagnostics; validator.standardError = diagnostics
        try validator.run(); validator.waitUntilExit()
        let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
        guard validator.terminationStatus == 0,
              let summary = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SchedulerCandidateError.invalid("original Session protocol validation: " + String(
                decoding: data,
                as: UTF8.self
            ))
        }
        return summary
    }

    func testReplayRecordedSessionInputs() throws {
        guard let path = ProcessInfo.processInfo.environment["BCR_J4_REPLAY_ARCHIVE"] else {
            // No fake live session: the full executor requires an archive after all native workers.
            var candidate = SchedulerCandidate()
            _ = try candidate.apply(.init(owner: "host-binding-negative", ordinal: 1, input: .initialize(.unlimited)))
            let item = try SchedulerItem(key: "same-key", value: .object(["wire": J4P.s("original")]), scope: J4P.null)
            let proposal = try candidate.apply(.init(
                owner: "host-binding-negative",
                ordinal: 2,
                input: .requestDirect(item)
            )).proposals[0]
            let substituted = try SchedulerItem(
                key: item.key,
                value: .object(["wire": J4P.s("substituted")]),
                scope: J4P.null
            )
            let plan = try SchedulerTracePlan(
                reference: J4P.s(item.key),
                payload: substituted.value,
                origin: J4P.s("interface"),
                scope: J4P.null,
                source: .simulation,
                endpointEvidence: .init(
                    endpointID: nil,
                    deviceID: nil,
                    connectionGeneration: 0,
                    transportOrigin: .unknown
                ),
                capturedEvidence: SchedulerTraceCodec.queuedEvidence(for: substituted, nativeDispatch: J4P.null),
                targetID: item.key,
                affectedElements: [],
                classification: .display,
                sideEffects: [],
                deliveryMode: .direct
            )
            let gate = SchedulerGateRecord(
                proposalOrdinal: proposal.ordinal,
                proposedItem: substituted,
                dispatchPlan: plan,
                proof: .init(
                    plan: plan,
                    nativeSnapshot: J4P.null,
                    authorization: .granted(directions: [.display]),
                    safety: .passed
                ),
                currentScope: J4P.null,
                currentNativeSnapshot: J4P.null
            )
            XCTAssertThrowsError(try candidate.apply(.init(
                owner: "host-binding-negative",
                ordinal: 3,
                input: .gate(gate)
            )))
            XCTAssertEqual(candidate.snapshot.inputOrdinal, 2) // Rejection cannot consume or replace the own proposal.
            XCTAssertEqual(candidate.snapshot.awaitingGate.map(\.item), [item])
            let receiptReference = J4P.s("actual-original-receipt-reference")
            XCTAssertNoThrow(try J4SessionReplay.exactCacheDedupEvidence(
                item: item,
                cache: [item.key: item],
                receipt: receiptReference
            ))
            XCTAssertThrowsError(try J4SessionReplay.exactCacheDedupEvidence(
                item: item,
                cache: [:],
                receipt: receiptReference
            ))
            XCTAssertThrowsError(try J4SessionReplay.exactCacheDedupEvidence(
                item: item,
                cache: [item.key: substituted],
                receipt: receiptReference
            ))
            XCTAssertThrowsError(try J4SessionReplay.exactCacheDedupEvidence(
                item: item,
                cache: [item.key: item],
                receipt: nil
            ))
            return
        }
        let root = URL(fileURLWithPath: path)
        let processFilter = ProcessInfo.processInfo.environment["BCR_J4_REPLAY_PROCESS"]
        if let processFilter {
            guard UInt32(processFilter) != nil else { throw SchedulerCandidateError.invalid("process selector") }
        }
        let resultRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BCR_J4_REPLAY_RESULT_ROOT"] ?? path)
        let output = resultRoot.appending(path: "session-candidate" + (processFilter.map { "-" + $0 } ?? ""))
        guard !FileManager.default.fileExists(atPath: output.path)
        else { throw SchedulerCandidateError.invalid("reused output") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let sessionFiles = files
            .filter { $0.lastPathComponent.hasPrefix("session-input-") && $0.pathExtension == "jsonl" &&
                (processFilter == nil || $0.lastPathComponent == "session-input-" + processFilter! + ".jsonl")
            }
        guard !sessionFiles.isEmpty else { throw SchedulerCandidateError.invalid("missing session inputs") }
        var reports: [[String: Any]] = []
        for file in sessionFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let majorTiming = J4ReplayTiming(includeChildren: true)
            let sourceInputIntegrity = try majorTiming.measure("original_input_integrity") {
                try validateOriginalSources(file, outputs: false)
            }
            let suffix = file.lastPathComponent.dropFirst("session-input-".count)
            let queueFile = root.appending(path: "scheduler-input-" + suffix)
            var events: [(UInt64, Bool, Data)] = []
            try majorTiming.measure("original_causal_header_collection") {
                for (input, queue) in [(file, false), (queueFile, true)] {
                    for line in try Data(contentsOf: input).split(separator: 10) {
                        let event = try j4Pool { () -> (UInt64, Bool, Data) in
                            let bytes = Data(line)
                            guard let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                                  let context = raw["context"] as? [String: Any],
                                  let text = context["causal_ordinal"] as? String,
                                  let ordinal = UInt64(text),
                                  String(ordinal) == text else { throw SchedulerCandidateError.ordinalMismatch }
                            return (ordinal, queue, bytes)
                        }
                        events.append(event)
                    }
                }
            }
            events.sort { $0.0 < $1.0 } // Global causal input cursor only; no native item/queue reordering.
            guard Set(events.map(\.0)).count == events.count else { throw SchedulerCandidateError.ordinalMismatch }
            let archive = try J4LosslessCatalog(directory: output, suffix: String(suffix))
            let replay = J4SessionReplay(archive: archive)
            try majorTiming.measure("original_event_replay_inclusive") {
                for (_, queue, bytes) in events {
                    try j4Pool {
                        if queue { try replay.scheduler(J4PayloadCodec.envelope(bytes)) }
                        else { try replay.session(J4PayloadCodec.payload(bytes)) }
                    }
                }
            }
            guard replay.admissions.isEmpty
            else { throw SchedulerCandidateError.invalid("unfinished original admission") }
            // Only now open native result files as comparison references, never as candidate inputs.
            let sourceOutputIntegrity = try majorTiming.measure("original_output_integrity") {
                try validateOriginalSources(file, outputs: true)
            }
            try majorTiming.measure("native_output_reference_comparison") {
                let nativeQueue = root.appending(path: "scheduler-native-" + suffix)
                for line in try Data(contentsOf: nativeQueue).split(separator: 10) {
                    try j4Pool {
                        let native = try J4P.object(J4PayloadCodec.payload(Data(line)))
                        let owner = try J4P.text(native["owner"]),
                            key = owner + ":" + String(try J4P.uint(native["ordinal"]))
                        guard let candidate = replay.queueComparisons[key],
                              let output = native["output"]
                        else {
                            throw SchedulerCandidateError.invalid("missing per-ordinal whole-system queue comparison")
                        }
                        for delta in SchedulerTraceDiff.compare(reference: output, candidate: candidate) {
                            try replay.difference(
                                "queue_policy_or_downstream_alignment_requires_root_classification",
                                ["association": J4P.s(key),
                                 "path": J4P
                                     .s(delta
                                         .path),
                                 "native": delta
                                     .reference ??
                                     J4P
                                     .null,
                                 "candidate": delta
                                     .candidate ??
                                     J4P
                                     .null,
                                 "native_present": .scalar(.flag(delta
                                         .reference !=
                                         nil)),
                                 "candidate_present": .scalar(.flag(delta
                                         .candidate !=
                                         nil)),
                                 "causal_policy_history": .array(replay.queuePolicyCauses[key, default: []])]
                            )
                        }
                    }
                }
                let nativeSession = root.appending(path: "session-native-" + suffix)
                for line in try Data(contentsOf: nativeSession).split(separator: 10) {
                    try j4Pool {
                        let native = try J4P.object(J4PayloadCodec.payload(Data(line)))
                        let key = try J4P.text(native["owner"]) + ":" + String(J4P.uint(native["ordinal"]))
                        guard let intent = replay.intents[key]
                        else { throw SchedulerCandidateError.invalid("missing original intent for native disposition") }
                        let output = try J4P.object(native["output"]!),
                            disposition = try J4P.text(output["disposition"])
                        let ownDisposition = intent
                            .queued ? "enqueue" : (intent.proposals.isEmpty ? "deduplicated" : "send")
                        if disposition != ownDisposition {
                            try replay.difference(
                                disposition == "suppressed_observe" ? "native_device_policy_withdrawal" :
                                    "accepted_cache_direct_dedup",
                                [
                                    "association": J4P.s(key),
                                    "original_input_reference": J4P.s(key),
                                    "native_disposition": J4P.s(disposition),
                                    "candidate_disposition": J4P.s(ownDisposition),
                                    "own_pre_gate_proposals": .array(intent.proposals
                                        .map { SchedulerTraceCodec.itemPayload($0.item) })
                                ]
                            )
                        }
                    }
                }
            }
            for (owner, pending) in replay.available where replay.sessionOwners.contains(owner) && !pending.isEmpty {
                try replay.difference("candidate_only_proposals_without_original_fresh_gate", ["owner": J4P.s(owner),
                                                                                               "proposals": .array(pending
                                                                                                   .map {
                                                                                                       SchedulerTraceCodec
                                                                                                           .itemPayload($0
                                                                                                               .item)
                                                                                                   }),
                                                                                               "causal_policy_history": .array(replay
                                                                                                   .policyCauses[
                                                                                                       owner,
                                                                                                       default: []
                                                                                                   ])])
            }
            guard replay.coldSteps == replay.inputCount,
                  archive.stepCount == replay.inputCount
            else { throw SchedulerCandidateError.invalid("missing streaming cold replay step") }
            reports.append([
                "source": file.lastPathComponent,
                "direct_requests": replay.direct,
                "queue_intents": replay.queued,
                "own_gates": replay.gates,
                "actual_admission_receipts": replay.receipts,
                "classified_differences": archive.differenceCount,
                "canonical_input_records": replay.inputCount,
                "catalog_entries": archive.catalogCount,
                "input_only_cold_replay": true,
                "native_output_used_as_state": false,
                "major_stage_seconds": majorTiming.seconds,
                "major_stage_cpu_seconds": majorTiming.cpuSeconds,
                "major_clock_definition": "wall seconds; parent+validator child CPU seconds. event_replay includes nested stage_seconds; do not sum both levels",
                "stage_seconds": replay.timing.seconds,
                "stage_cpu_seconds": replay.timing.cpuSeconds,
                "stage_clock_definition": "wall=monotonic seconds; cpu=process CPU seconds (clock/CLOCKS_PER_SEC)",
                "original_input_integrity": sourceInputIntegrity,
                "original_output_integrity": sourceOutputIntegrity
            ])
        }
        if processFilter == nil {
            guard reports.reduce(0, { $0 + ($1["own_gates"] as! Int) }) > 0,
                  reports.reduce(0, { $0 + ($1["actual_admission_receipts"] as! Int) }) > 0
            else { throw SchedulerCandidateError.invalid("missing reached gate/receipt families") }
        }
        try JSONSerialization.data(
            withJSONObject: [
                "scope": "own direct/queued proposals, fresh original Session gates, admission receipts; no physical observation",
                "processes": reports
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: output.appending(path: "report.json"))
    }
}
