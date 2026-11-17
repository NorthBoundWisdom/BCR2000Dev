import BCRFoundation
import Foundation
import SurfaceBindingContext
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning

/// Full raw attribution is distinct from the legacy semantic current-scope predicate.
struct BCRFeedbackEvidence: Equatable, Sendable {
    let source: DeviceSource
    let context: SurfaceEventContext
    let endpoint: MIDIEndpointSource?
    let expectedEndpoint: MIDIEndpointSource?
    let expectedMapping: UInt64?
    let connection: MIDIConnectionSnapshot
    let parameterContext: ParameterWriteContext?
    let publicationRevision: UInt64?
    let queueGeneration: UInt64
    let hardwareOutput: HardwareOutputPolicy
    let receiptIdentity: String?
    let acceptedHookPresent: Bool
    let legacyQueued: ScheduledFeedback?
    let resolvedGenerationTiming: FeedbackTiming?
}

struct BCRFeedbackNativeSnapshot: Equatable, Sendable {
    let evidence: BCRFeedbackEvidence
    let deviceConnection: MIDIConnectionSnapshot
}

typealias BCRFeedbackPlan = SurfaceFeedbackPlanning.FeedbackPlan<MIDIVoiceMessage, SurfaceWriteOrigin,
    ContextScope, MIDIControlID, BCRFeedbackEvidence>

/// Device fact projection only. Core values/results are the primary runtime decisions.
enum FeedbackRuntime {
    static func plan(message: MIDIVoiceMessage, origin: SurfaceWriteOrigin, timing: FeedbackTiming,
                     control: BCRControlID?, evidence: BCRFeedbackEvidence) -> BCRFeedbackPlan
    {
        let target = control
            .map(BCRNeutralSurfaceProjection.logicalTargetID) ?? ("midi." + FeedbackJ4Trace.key(message.controlID))
        return try! BCRFeedbackPlan(reference: message.controlID, payload: message, origin: origin,
                                    scope: BCRKernelProjection.scope(
                                        source: evidence.source,
                                        generation: evidence.context.generation,
                                        mapping: evidence.context.mappingGeneration,
                                        endpoint: evidence.endpoint
                                    ),
                                    source: BCRNeutralSurfaceProjection.source(evidence.source),
                                    endpointEvidence: try! BCRNeutralSurfaceProjection.endpoint(evidence.endpoint),
                                    capturedEvidence: evidence,
                                    targetID: target,
                                    affectedElements: Set(control
                                        .map { [BCRNeutralSurfaceProjection.elementID($0)] } ?? []),
                                    classification: .display, sideEffects: [],
                                    deliveryMode: timing == .coalesced ? .coalescible : .direct)
    }

    /// Generation's original observe gate; parameter permission remains at the later IO stage.
    static func generationAuthorization(_ evidence: BCRFeedbackEvidence) -> PlanAuthorization {
        evidence.source == .hardware && evidence.hardwareOutput == .observe
            ? .denied(reason: "observe") : .granted(directions: [.display])
    }

    @discardableResult
    static func capture(owner: String, plan: BCRFeedbackPlan, phase: String,
                        nativeMessage: MIDIVoiceMessage, nativeOrigin: SurfaceWriteOrigin, nativeTiming: FeedbackTiming,
                        nativeControl: BCRControlID?, evidence: BCRFeedbackEvidence, map: HardwareMap) -> Int?
    {
        guard FeedbackJ4Trace.enabled else { return nil }
        return FeedbackJ4Trace.actual(owner: owner, operation: "capture_" + phase,
                                      input: [
                                          "message": FeedbackJ4Trace.message(nativeMessage),
                                          "origin": nativeOrigin.rawValue,
                                          "timing": nativeTiming == .coalesced ? "coalesced" : "synchronous",
                                          "control": nativeControl
                                              .map { try! JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                                              } as Any? ?? NSNull(),
                                          "hardware_map": FeedbackJ4Trace.hardwareMap(map),
                                          "evidence": value(evidence)
                                      ], actual: value(plan))
    }

    static func skipped(owner: String, plan: BCRFeedbackPlan, capture: Int?, reason: String) {
        guard FeedbackJ4Trace.enabled else { return }
        FeedbackJ4Trace.actual(owner: owner, operation: "native_gate_rejected_before_full_preflight",
                               input: [
                                   "plan_capture": capture.map(String.init) as Any? ?? NSNull(),
                                   "plan": value(plan),
                                   "reason": reason
                               ],
                               actual: ["full_preflight_executed": false])
    }

    static func receipt(owner: String, fact: FeedbackReceiptFact<BCRFeedbackPlan>, capture: Int?,
                        currentScope: ContextScope?, currentEvidence: BCRFeedbackEvidence? = nil)
    {
        guard FeedbackJ4Trace.enabled else { return }
        let current = currentScope.map { FeedbackReceiptEligibility.matchesCurrentScope(fact, currentScope: $0) }
        let eligible = currentScope.map { FeedbackReceiptEligibility.acceptedInCurrentScope(fact, currentScope: $0) }
        FeedbackJ4Trace.actual(owner: owner, operation: "receipt", input: [
            "plan_capture": capture.map(String.init) as Any? ?? NSNull(), "plan": value(fact.plan),
            "result": value(fact.result),
            "current_scope": currentScope.map(value) as Any? ?? NSNull(),
            "current_evidence": currentEvidence.map(value) as Any? ?? NSNull(),
            "attempt_layer": "SurfaceDevice.send admission call", "underlying_native_transport_attempt": NSNull(),
            "physical_bytes_written": NSNull(), "actual_observation": false
        ], actual: [
            "attempted": fact.hasTransportAttempt, "successful": fact.successfulSend,
            "current": current as Any? ?? NSNull(), "accepted_in_current_scope": eligible as Any? ?? NSNull()
        ])
    }

    @MainActor
    static func boundary(owner: String, phase: String, plan: BCRFeedbackPlan, capture: Int?, currentScope: ContextScope,
                         delivery: FeedbackDelivery, queueGeneration: UInt64, nextEventID: Int,
                         echoIDs: @autoclosure () -> [String: [String]], receipt: FeedbackReceipt?)
    {
        guard FeedbackJ4Trace.enabled else { return }
        FeedbackJ4Trace.actual(owner: owner, operation: "boundary_" + phase, input: [
            "plan_capture": capture.map(String.init) as Any? ?? NSNull(), "plan": value(plan),
            "current_scope": value(currentScope),
            "delivery": delivery.rawValue, "queue_generation": String(queueGeneration), "next_event_id": nextEventID,
            "echo_ids": echoIDs(),
            "receipt_deliveries": receipt
                .map { $0.deliveries.map { $0?.rawValue as Any? ?? NSNull() } } as Any? ?? NSNull(),
            "completion_error_present": receipt?.completionError != nil
        ], actual: [:])
    }

    @MainActor
    static func summary(owner: String, receipt: FeedbackReceipt, summary: FeedbackReceiptSummary) {
        guard FeedbackJ4Trace.enabled else { return }
        FeedbackJ4Trace.actual(owner: owner, operation: "summary", input: [
            "deliveries": receipt.deliveries.map { $0?.rawValue as Any? ?? NSNull() },
            "completion_error_present": receipt.completionError != nil
        ], actual: [
            "all_accepted": summary.allAccepted, "any_accepted": summary.anyAccepted,
            "attempt_count": summary.attemptCount,
            "accepted_count": summary.acceptedCount, "rejected_count": summary.rejectedCount,
            "not_attempted_count": summary.notAttemptedCount
        ])
    }

    static func value(_ authorization: PlanAuthorization) -> [String: Any] {
        switch authorization {
        case let .granted(directions): ["case": "granted", "directions": directions.map(\.rawValue).sorted()]
        case let .denied(reason): ["case": "denied", "reason": reason]
        }
    }

    static func value(_ decision: FeedbackPreflight) -> [String: Any] {
        if decision == .permitted { return ["case": "permitted"] }
        guard case let .rejected(reason) = decision else { preconditionFailure("Unknown feedback result") }
        switch reason {
        case .planMismatch: return ["case": "rejected", "reason": "plan_mismatch"]
        case .staleScope: return ["case": "rejected", "reason": "stale_scope"]
        case .staleNativeProof: return ["case": "rejected", "reason": "stale_native_proof"]
        case let .authorizationDenied(reason): return [
                "case": "rejected",
                "reason": "authorization_denied",
                "native_reason": reason
            ]
        case let .wrongDirections(missing, surplus): return [
                "case": "rejected",
                "reason": "wrong_directions",
                "missing": missing.map(\.rawValue).sorted(),
                "surplus": surplus.map(\.rawValue).sorted()
            ]
        case let .nativeRejected(reason): return [
                "case": "rejected",
                "reason": "native_rejected",
                "native_reason": reason
            ]
        }
    }

    static func value(_ safety: NativeSafetyResult) -> [String: Any] {
        switch safety {
        case .passed: ["case": "passed"]
        case let .rejected(reason): ["case": "rejected", "reason": reason]
        }
    }

    static func value(_ result: FeedbackAttemptResult) -> [String: Any] {
        switch result {
        case .accepted: ["case": "accepted"]
        case let .notAttempted(reason): ["case": "notAttempted", "reason": reason]
        case let .rejected(reason): ["case": "rejected", "reason": reason]
        }
    }

    static func value(_ scope: ContextScope) -> [String: Any] {
        ["source": scope.source.rawValue, "context_id": scope.context.id, "generation": scope.context.generation,
         "mapping_revision": scope.context.mappingRevision as Any? ?? NSNull(),
         "endpoint": scope.endpoint.map { ["endpoint_id": $0.endpointID as Any? ?? NSNull(),
                                           "device_id": $0.deviceID as Any? ?? NSNull(),
                                           "connection_generation": String($0.connectionGeneration),
                                           "transport_origin": $0.transportOrigin.rawValue] as [String: Any]
         } as Any? ??
             NSNull()]
    }

    static func value(_ evidence: BCRFeedbackEvidence) -> [String: Any] {
        let permission: Any = evidence.parameterContext.map { context in
            [
                "source": context.source.rawValue,
                "generation": context.generation,
                "mapping_revision": String(context.mappingRevision),
                "identities": context.identities.map(\.rawValue).sorted(),
                "parameters": context.parameters.map { $0.map(\.rawValue).sorted() } as Any? ?? NSNull(),
                "allows_write": context.allowsWrite,
                "allows_display": context.allowsDisplay
            ] as [String: Any]
        } ?? NSNull()
        return ["source": evidence.source.rawValue, "context": FeedbackJ4Trace.context(evidence.context),
                "endpoint": FeedbackJ4Trace.endpoint(evidence.endpoint),
                "expected_endpoint": FeedbackJ4Trace.endpoint(evidence.expectedEndpoint),
                "expected_mapping": evidence.expectedMapping.map(String.init) as Any? ?? NSNull(),
                "connection": FeedbackJ4Trace.connection(evidence.connection), "parameter_context": permission,
                "publication_revision": evidence.publicationRevision.map(String.init) as Any? ?? NSNull(),
                "queue_generation": String(evidence.queueGeneration),
                "hardware_output": evidence.hardwareOutput.rawValue,
                "receipt_identity": evidence.receiptIdentity as Any? ?? NSNull(),
                "accepted_hook_present": evidence.acceptedHookPresent,
                "legacy_queued": evidence.legacyQueued.map(FeedbackJ4Trace.scheduled) as Any? ?? NSNull(),
                "resolved_generation_timing": evidence.resolvedGenerationTiming
                    .map { $0 == .coalesced ? "coalesced" : "synchronous" } as Any? ?? NSNull()]
    }

    static func value(_ snapshot: BCRFeedbackNativeSnapshot) -> [String: Any] {
        [
            "evidence": value(snapshot.evidence),
            "device_connection": FeedbackJ4Trace.connection(snapshot.deviceConnection)
        ]
    }

    static func value(_ plan: BCRFeedbackPlan) -> [String: Any] {
        [
            "reference": FeedbackJ4Trace.key(plan.reference),
            "payload": FeedbackJ4Trace.message(plan.payload),
            "origin": plan.origin.rawValue,
            "scope": value(plan.scope),
            "source": plan.source.rawValue,
            "endpoint_evidence": [
                "endpoint_id": plan.endpointEvidence.endpointID as Any? ?? NSNull(),
                "device_id": plan.endpointEvidence.deviceID as Any? ?? NSNull(),
                "connection_generation": String(plan.endpointEvidence.connectionGeneration),
                "transport_origin": plan.endpointEvidence.transportOrigin.rawValue
            ],
            "captured_evidence": value(plan.capturedEvidence),
            "target_id": plan.targetID,
            "affected_elements": plan.affectedElements.sorted(),
            "classification": plan.classification.rawValue,
            "side_effects": plan.sideEffects.map(\.rawValue).sorted(),
            "required_directions": plan.requiredDirections.map(\.rawValue).sorted(),
            "delivery_mode": plan.deliveryMode == .direct ? "direct" : "coalescible"
        ]
    }
}
