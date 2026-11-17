import BCRFoundation
import Foundation
@testable import BCRSurfaceDomain
import SurfaceBindingContext
import SurfaceFeedbackPlanning

// Construction/accessor compatibility for the unchanged original assertions.
// Every decision is the actual Core result; this contains no legacy algorithm.
typealias FeedbackPlan = BCRFeedbackPlan
extension SurfaceFeedbackPlanning.FeedbackPlan where Payload == MIDIVoiceMessage, Origin == SurfaceWriteOrigin,
    Scope == ContextScope, Reference == MIDIControlID, CapturedEvidence == BCRFeedbackEvidence
{
    init(message: MIDIVoiceMessage, origin: SurfaceWriteOrigin, timing: FeedbackTiming) {
        let evidence = BCRFeedbackEvidence(source: .mock,
                                           context: .init(generation: "plan-unit-fixture", mappingGeneration: 0),
                                           endpoint: nil,
                                           expectedEndpoint: nil, expectedMapping: nil, connection: .init(),
                                           parameterContext: nil,
                                           publicationRevision: nil, queueGeneration: 0, hardwareOutput: .write,
                                           receiptIdentity: nil,
                                           acceptedHookPresent: false, legacyQueued: nil,
                                           resolvedGenerationTiming: timing)
        self = FeedbackRuntime.plan(message: message, origin: origin, timing: timing, control: nil, evidence: evidence)
    }

    var message: MIDIVoiceMessage { payload }
    var timing: FeedbackTiming { deliveryMode == .direct ? .synchronous : .coalesced }
}

extension FeedbackScheduler {
    static func dispatch(_ plan: BCRFeedbackPlan, canCoalesce: Bool) -> FeedbackDispatchChoice {
        plan.dispatchChoice(canCoalesce: canCoalesce)
    }
}

extension FeedbackPlanner {
    func message(_ message: MIDIVoiceMessage, origin: SurfaceWriteOrigin,
                 requestedTiming: FeedbackTiming?) -> BCRFeedbackPlan
    {
        .init(message: message, origin: origin, timing: resolvedTiming(requested: requestedTiming))
    }
}
