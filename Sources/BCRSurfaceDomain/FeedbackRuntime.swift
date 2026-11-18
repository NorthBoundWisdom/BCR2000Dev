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
        let reference = message.controlID
        let target = control.map(BCRNeutralSurfaceProjection.logicalTargetID) ??
            "midi.\(reference.kind.rawValue).\(reference.channel).\(reference.number)"
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
}
