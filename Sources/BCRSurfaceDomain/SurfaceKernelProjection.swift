import BCRFoundation
import Foundation
import SurfaceBindingContext
import SurfaceConnectionState
import SurfaceDeviceContracts

/// Native route identity beyond the common selected IDs and transport generation.
struct BCRConnectionIdentity: Equatable, Sendable {
    let inputName: String?
    let outputName: String?
    let inputOrigin: MIDIEndpointProvenance?
    let outputOrigin: MIDIEndpointProvenance?
}

/// Protocol/configuration projection only. Payloads remain in their original native owners.
enum BCRKernelProjection {
    static func connection(_ value: MIDIConnectionSnapshot) -> ConnectionSnapshot<BCRConnectionIdentity> {
        try! ConnectionSnapshot(
            inputID: value.connectedSourceID.map(String.init),
            outputID: value.connectedDestinationID.map(String.init),
            transportGeneration: value.transportGeneration.map(UInt64.init), isConnected: value.isConnected,
            extra: BCRConnectionIdentity(
                inputName: value.connectedSource, outputName: value.connectedDestination,
                inputOrigin: value.sourceEndpoints.first { $0.id == value.connectedSourceID }?.provenance,
                outputOrigin: value.destinationEndpoints.first { $0.id == value.connectedDestinationID }?.provenance
            )
        )
    }

    static func scope(source: DeviceSource, generation: String, mapping: UInt64,
                      endpoint: MIDIEndpointSource?) -> ContextScope
    {
        // Reuse the established unknown-preserving endpoint projection.
        let projectedEndpoint = endpoint.map { try! BCRNeutralSurfaceProjection.endpoint($0) }
        return ContextScope(
            source: source == .hardware ? .hardware : .simulation,
            context: try! DeviceContext(id: "surface.lifecycle", generation: "input-epoch:" + generation,
                                        mappingRevision: String(mapping)),
            endpoint: projectedEndpoint
        )
    }

    static func bindings(_ assignments: [ControlAssignment]) -> BindingContext {
        BindingContext(
            context: try! DeviceContext(
                id: "configuration.lookup",
                generation: "ordered.entries",
                mappingRevision: nil
            ),
            controlEntries: assignments.enumerated().map { offset, assignment in
                try! ControlBinding(
                    elementID: BCRNeutralSurfaceProjection.elementID(assignment.control),
                    facetID: BCRNeutralSurfaceProjection.logicalTargetID(assignment.control),
                    targetReferenceID: String(offset)
                )
            }
        )
    }

    static func bindingReference(_ control: BCRControlID, in bindings: BindingContext) -> String? {
        bindings.targetForControl(elementID: BCRNeutralSurfaceProjection.elementID(control),
                                  facetID: BCRNeutralSurfaceProjection.logicalTargetID(control))
    }
}

/// Kit owns connection facts and generation. Publication stays at the native
/// callback boundary; temporary reduction never publishes the route ahead of observers.
struct BCRConnectionRuntime: Sendable {
    private(set) var snapshot: ConnectionSnapshot<BCRConnectionIdentity>
    private(set) var generation: UInt64

    init(snapshot: MIDIConnectionSnapshot, generation: UInt64) {
        self.snapshot = BCRKernelProjection.connection(snapshot); self.generation = generation
    }

    mutating func begin(_ next: MIDIConnectionSnapshot) -> ConnectionTransition<BCRConnectionIdentity> {
        var reducer = ConnectionState(snapshot: snapshot, connectionGeneration: generation)
        let transition = reducer.apply(BCRKernelProjection.connection(next))
        generation = transition.currentGeneration
        return transition
    }

    mutating func publish(_ next: MIDIConnectionSnapshot) { snapshot = BCRKernelProjection.connection(next) }
}

/// Captured metadata only; scheduled MIDI payloads remain in FeedbackScheduler.pending.
struct BCRFeedbackQueueScope: Equatable, Sendable {
    let origin: SurfaceWriteOrigin
    let endpoint: MIDIEndpointSource?
    let mappingRevision: UInt64?
    let source: DeviceSource?
    let context: SurfaceEventContext?

    init(_ value: ScheduledFeedback) {
        origin = value.origin; endpoint = value.endpoint; mappingRevision = value.mappingRevision
        source = value.source; context = value.context
    }
}

// Temporary O-4 scheduler I/O archive projection; removed with FeedbackJ4Trace.
extension BCRKernelProjection {
    static func controlValue(_ value: BCRControlID) -> [String: Any] {
        ["section": value.section.rawValue, "row": value.row, "index": value.index]
    }
}
