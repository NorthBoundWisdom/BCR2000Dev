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
        // Reuse the established unknown-preserving endpoint projection. The raw
        // native endpoint is retained separately in every shadow record.
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

extension BCRKernelProjection {
    static func controlValue(_ value: BCRControlID) -> [String: Any] {
        ["section": value.section.rawValue, "row": value.row, "index": value.index]
    }

    static func midiValue(_ value: MIDIControlID) -> [String: Any] {
        ["kind": value.kind.rawValue, "channel": value.channel, "number": value.number]
    }

    static func endpointValue(_ value: MIDIEndpointSource?) -> Any {
        guard let value else { return NSNull() }
        return ["endpoint_id": value.endpointID, "device_id": value.deviceID.map { $0 as Any } ?? NSNull(),
                "connection_generation": value.connectionGeneration, "provenance": value.provenance.rawValue]
    }

    static func contextValue(_ value: SurfaceEventContext?) -> Any {
        guard let value else { return NSNull() }
        return ["generation": value.generation, "mapping_generation": value.mappingGeneration,
                "known_device_context": value.knownDeviceContextID.map { $0 as Any } ?? NSNull()]
    }

    static func queueScopeValue(_ value: BCRFeedbackQueueScope) -> [String: Any] {
        ["origin": value.origin.rawValue, "endpoint": endpointValue(value.endpoint),
         "mapping_revision": value.mappingRevision.map { $0 as Any } ?? NSNull(),
         "source": value.source.map { $0.rawValue as Any } ?? NSNull(), "context": contextValue(value.context)]
    }

    static func connectionValue(_ value: MIDIConnectionSnapshot) -> [String: Any] {
        func descriptors(_ values: [MIDIEndpointDescriptor]) -> [[String: Any]] {
            values.map { ["id": $0.id, "name": $0.name, "availability_known": $0.availabilityKnown,
                          "provenance": $0.provenance.rawValue] }
        }
        return ["input_id": value.connectedSourceID.map { $0 as Any } ?? NSNull(),
                "output_id": value.connectedDestinationID.map { $0 as Any } ?? NSNull(),
                "transport_generation": value.transportGeneration.map { $0 as Any } ?? NSNull(),
                "is_connected": value.isConnected,
                "input_name": value.connectedSource.map { $0 as Any } ?? NSNull(),
                "output_name": value.connectedDestination.map { $0 as Any } ?? NSNull(),
                "input_endpoints": descriptors(value.sourceEndpoints),
                "output_endpoints": descriptors(value.destinationEndpoints),
                "input_names": value.sourceNames, "output_names": value.destinationNames,
                "last_error": value.lastError.map { $0 as Any } ?? NSNull()]
    }

    static func connectionProjectionValue(_ value: ConnectionSnapshot<BCRConnectionIdentity>) -> [String: Any] {
        ["input_id": value.inputID.map { $0 as Any } ?? NSNull(),
         "output_id": value.outputID.map { $0 as Any } ?? NSNull(),
         "transport_generation": value.transportGeneration.map { $0 as Any } ?? NSNull(),
         "is_connected": value.isConnected,
         "input_name": value.extra.inputName.map { $0 as Any } ?? NSNull(),
         "output_name": value.extra.outputName.map { $0 as Any } ?? NSNull(),
         "input_origin": value.extra.inputOrigin.map { $0.rawValue as Any } ?? NSNull(),
         "output_origin": value.extra.outputOrigin.map { $0.rawValue as Any } ?? NSNull()]
    }
}
