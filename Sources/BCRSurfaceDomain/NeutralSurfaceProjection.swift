import BCRFoundation
import Foundation
import SurfaceDeviceContracts

/// Device-adapter projections only. No business value store, input authority or IO.
public enum BCRNeutralSurfaceProjection: Sendable {
    /// Stable physical actuation role, independent of top-row encoder-group bindings.
    public static func elementID(_ control: BCRControlID) -> String {
        switch control.section {
        case .pushEncoder: "pushEncoder.rotate.\(control.index)"
        case .pushEncoderButton: "pushEncoder.press.\(control.index)"
        case .button, .encoder, .userButton: logicalTargetID(control)
        }
    }

    /// Existing published/group-qualified logical identity, not a physical element count.
    public static func logicalTargetID(_ control: BCRControlID) -> String {
        "\(control.section.rawValue).\(control.row).\(control.index)"
    }

    public static func facetContext(_ context: DeviceContext, control: BCRControlID?,
                                    knownDeviceContextID: String? = nil) throws -> DeviceContext
    {
        let facet = control.map(logicalTargetID) ?? "unknown"
        return try DeviceContext(id: context.id + "|binding-facet=" + facet +
            "|device-context=" + (knownDeviceContextID ?? "unknown"),
            generation: context.generation, mappingRevision: context.mappingRevision)
    }

    public static func source(_ source: DeviceSource) -> SurfaceDeviceContracts.DeviceSource {
        source == .mock ? .simulation : .hardware
    }

    public static func endpoint(_ endpoint: MIDIEndpointSource?) throws -> EndpointProvenance {
        try EndpointProvenance(
            endpointID: endpoint.flatMap { $0.endpointID == "unknown" ? nil : $0.endpointID },
            deviceID: endpoint?.deviceID,
            connectionGeneration: endpoint?.connectionGeneration ?? 0,
            transportOrigin: endpoint.map {
                switch $0.provenance {
                case .unknown: .unknown
                case .physicalUSB: .physicalUSB
                case .localVirtual: .localVirtual
                case .remoteVirtual: .remoteVirtual
                }
            } ?? .unknown
        )
    }

    /// Opaque generation identity; mappingRevision is not an incrementing counter/content claim.
    public static func context(instanceID: String, generation: String,
                               mappingGeneration: UInt64) throws -> DeviceContext
    {
        try DeviceContext(
            id: instanceID,
            generation: "\(generation):binding:\(mappingGeneration)",
            mappingRevision: nil
        )
    }

    public static func input(control: BCRControlID, message: MIDIVoiceMessage, mode: EncoderMode,
                             context: DeviceContext, endpoint: EndpointProvenance, source: DeviceSource,
                             at: Double, knownDeviceContextID: String? = nil,
                             pressMode: HardwarePressMode? = nil) throws -> DeviceInputEvent
    {
        let kind: InputKind
        let value: DeviceValue
        if control.isContinuous {
            kind = mode == .absolute ? .absolute : .relative
            value = .number(mode == .absolute ? Double(message.dataValue) :
                Double(mode.delta(value: message.dataValue, maximum: message.maximumDataValue)))
        } else {
            // Pulse/unknown encodings report a signal value; they do not prove a physical release/hold edge.
            kind = pressMode == .momentary ? (message.isPositiveActivation ? .press : .release) : .absolute
            value = .flag(message.isPositiveActivation)
        }
        return try DeviceInputEvent(elementID: elementID(control), kind: kind, value: value,
                                    context: facetContext(
                                        context,
                                        control: control,
                                        knownDeviceContextID: knownDeviceContextID
                                    ),
                                    endpoint: endpoint, source: self.source(source), at: at)
    }

    /// A genuine accepted input report, not a reconstructed physical absolute position.
    public static func observation(_ input: DeviceInputEvent) throws -> DeviceObservation {
        let role: String
        switch input.kind {
        case .absolute:
            if case .flag = input.value { role = "input.signal-state" }
            else { role = "input.position" }
        case .relative: role = "input.relative-delta"
        case .press, .release: role = "input.pressed"
        case .contactBegan, .contactEnded: role = "input.contact"
        }
        return try DeviceObservation(targetID: input.elementID + "." + role, value: input.value,
                                     state: .observed, evidence: .deviceReport, context: input.context,
                                     endpoint: input.endpoint, source: input.source, at: input.at)
    }

    public static func feedback(_ event: MonitorEvent, context: DeviceContext) throws -> EffectDescriptor? {
        guard event.direction == .output else { return nil }
        let element = event.control.map(elementID)
        return try EffectDescriptor(
            id: "native-event.\(event.id)",
            targetID: event.control.map(logicalTargetID) ?? "unmapped.output",
            affectedElements: Set(element.map { [$0] } ?? []),
            value: .number(Double(event.message.dataValue)),
            classification: .display,
            sideEffects: [],
            context: facetContext(context, control: event.control,
                                  knownDeviceContextID: event.context?
                                      .knownDeviceContextID),
            endpoint: endpoint(event.endpoint),
            source: source(event.source),
            timing: .immediate,
            at: event.monotonicTime
        )
    }

    public static func transmission(_ event: MonitorEvent, effect: EffectDescriptor) throws -> TransmissionEvidence? {
        let outcome: TransmissionOutcome
        switch event.delivery {
        case .sent: outcome = .accepted
        case .failed: outcome = .rejected(reason: "native_transport_rejected")
        // No actual device.send call was made. Keep these as decisions, not transmissions.
        case .disconnected, .suppressed, .none: return nil
        }
        return try TransmissionEvidence(effectID: effect.id, targetID: effect.targetID, context: effect.context,
                                        endpoint: effect.endpoint, source: effect.source, at: effect.at,
                                        outcome: outcome)
    }

    public static func capabilities(map: HardwareMap,
                                    configuration: SurfaceConfiguration) throws -> DeviceCapabilities
    {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let interpretation = map.entries.map { entry in
            ["logical_target": logicalTargetID(entry.control),
             "input_mode": entry.control.isContinuous ?
                 (configuration.assignment(for: entry.control)?.encoderMode ?? .absolute).rawValue : "button"]
        }
        // Content identity includes every input interpretation that changes the advertised capabilities.
        // It contains no business parameter values, definitions, bindings or generation counters.
        let identity = try JSONSerialization.data(withJSONObject: [
            "hardware_map_sha256": ContentDigest.sha256(try encoder.encode(map)),
            "input_interpretation": interpretation
        ], options: [.sortedKeys])
        let profile = "learned-map." + ContentDigest.sha256(identity)
        let physical = Dictionary(grouping: map.entries, by: { elementID($0.control) })
        let elements = try physical.keys.sorted().map { role -> ElementCapability in
            var inputs: [InputCapability] = []
            var displays: [DisplayCapability] = []
            for entry in physical[role]! {
                let continuous = entry.control.isContinuous
                let mode = configuration.assignment(for: entry.control)?.encoderMode ?? .absolute
                let facetInputs: [InputCapability] = continuous ? [
                    .init(kind: mode == .absolute ? .absolute : .relative, valueKind: .number)
                ] : (entry.pressMode == .momentary ?
                    [.init(kind: .press, valueKind: .flag), .init(kind: .release, valueKind: .flag)] :
                    [.init(kind: .absolute, valueKind: .flag)])
                for input in facetInputs where !inputs.contains(input) { inputs.append(input) }
                if entry.visualizationOnly != true {
                    let display = try DisplayCapability(kind: continuous ? "value" : "indicator", valueKind: .number)
                    if !displays.contains(display) { displays.append(display) }
                }
            }
            return try .init(elementID: role, inputs: inputs, displays: displays,
                             effects: displays.isEmpty ? [] : [try .init(kind: "display", classification: .display,
                                                                         sideEffects: [])])
        }
        // Encoder groups are binding facets, not protocol modes.
        return try DeviceCapabilities(profileID: profile, modes: [.init(id: "midi-1", elements: elements)])
    }
}
