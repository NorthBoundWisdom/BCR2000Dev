import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import Foundation
import SurfaceControlContracts
import SurfacePluginContracts

/// Optional hardware-only journal. The engine remains the sole parameter authority.
@MainActor
public final class BCRHardwareSurfaceControlAdapter {
    private let surface: SurfaceSession
    private let permissions: BCRSurfaceControlAdapter.Permissions
    private let principals: SurfaceControlPrincipals
    private let monotonic: @MainActor () -> Double
    private let epochFactory: @MainActor () -> String
    private var core: SurfaceControlSession
    private var context: UInt64
    private var generation: String
    private var source: DeviceSource
    private var prepared: (ControlHardwareInput, Double)?
    private struct FeedbackProperty: Hashable { let control: String; let kind: String }
    private var feedbackOrdinal: UInt64 = 0
    private var completedFeedbackOrdinals: [FeedbackProperty: UInt64] = [:]
    public private(set) var diagnostics: [String] = []

    public static func exclusions(_ surface: SurfaceSession) -> [String] {
        surface.learnedHardwareMap.entries.compactMap { entry in
            if entry.midi
                .kind == .nrpn { return BCRSurfaceControlAdapter.controlID(entry.control) + ": nrpn14 unqualified" }
            if entry.control.isContinuous,
               let mode = surface.engine.configuration.assignment(for: entry.control)?.encoderMode, mode != .absolute
            {
                return BCRSurfaceControlAdapter.controlID(entry.control) + ": relative encoding unqualified"
            }
            return nil
        }
    }

    public static func profile(_ surface: SurfaceSession, inputEventCapacity: Int? = nil) throws -> ControlProfile {
        let controls = surface.learnedHardwareMap.entries.compactMap { entry -> ControlDescriptor? in
            let control = entry.control
            let assignment = surface.engine.configuration.assignment(for: control)
            guard entry.midi.kind != .nrpn,
                  !control.isContinuous || assignment == nil || assignment?.encoderMode == .absolute else { return nil }
            return ControlDescriptor(id: BCRSurfaceControlAdapter.controlID(control),
                                     inputKind: control.isContinuous ? .absolute : .button,
                                     encoding: control.isContinuous ? .scalar : .boolean,
                                     range: control.isContinuous ? .init(minimum: 0, maximum: 127, step: 1) : nil,
                                     feedbackRange: control.isContinuous && entry.visualizationOnly != true ?
                                         .init(minimum: 0, maximum: 127, step: 1) : nil,
                                     feedbackKinds: entry.visualizationOnly == true ? [] :
                                         (control.isContinuous ? [.value] : [.indicator]),
                                     mapping: assignment?.target.parameterID.map { .init(
                                         kind: .parameter,
                                         id: $0.rawValue
                                     ) },
                                     acceptsInput: false)
        }
        // Physical routing is part of the content pin, including unknown versus declared press modes.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // A failed encoding must not publish a fingerprint of empty bytes.
        let bytes = try encoder.encode(surface.learnedHardwareMap)
        var fingerprint: UInt64 = 14695981039346656037
        for byte in bytes { fingerprint = (fingerprint ^ UInt64(byte)) &* 1099511628211 }
        var capabilities = ["hardware", "controls.stable_ids", "controls.input_declared", "feedback.unsequenced",
                            "input.independent_sequence", "events.writer_id",
                            "x.bcr.hardware_map." + String(fingerprint, radix: 16), "x.bcr.indicator_blink_static"]
        for kind in [ControlInputKind.absolute, .button] where controls.contains(where: { $0.input_kind == kind }) {
            capabilities.append("input." + kind.rawValue)
        }
        for kind in [ControlFeedbackKind.value, .indicator]
            where controls.contains(where: { $0.feedback_kinds.contains(kind) })
        {
            capabilities.append("feedback." + kind.rawValue)
        }
        if inputEventCapacity != nil { capabilities.append("events.input_retention") }
        return ControlProfile(id: "bcr2000.hardware", version: inputEventCapacity == nil ? "1.4" : "1.5",
                              controls: controls, capabilities: capabilities)
    }

    public static func publishedContract(surface: SurfaceSession, inputEventCapacity: Int? = nil) throws -> JSONValue {
        let core = try SurfaceControlSession(
            instanceID: "example.hardware",
            epoch: "discovery-only",
            profile: try profile(surface, inputEventCapacity: inputEventCapacity),
            inputEventCapacity: inputEventCapacity
        )
        return try .object(["discovery": .encoded(core.discovery()),
                            "tools": .array((SurfaceControlTools
                                    .descriptors(source: .hardware) + (inputEventCapacity == nil ? [] :
                                        SurfaceControlInputEventsTools.descriptors(source: .hardware)))
                                .map { try .encoded($0) }),
                            "excluded_controls": .array(exclusions(surface).map(JSONValue.string)),
                            "hardware_group": .string("unknown")])
    }

    public init(surface: SurfaceSession, instanceID: String, permissions: BCRSurfaceControlAdapter.Permissions,
                principals: SurfaceControlPrincipals = .init(), eventCapacity: Int = 1024,
                inputEventCapacity: Int? = nil,
                monotonic: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
                epochFactory: @escaping @MainActor () -> String = { UUID().uuidString }) throws
    {
        self.epochFactory = epochFactory
        self.surface = surface; self.permissions = permissions; self.principals = principals; self.monotonic = monotonic
        context = surface.mappingContextRevision; generation = surface.inputEvents.generation; source = surface.source
        core = try SurfaceControlSession(
            instanceID: instanceID,
            epoch: epochFactory(),
            profile: try Self.profile(surface, inputEventCapacity: inputEventCapacity),
            eventCapacity: eventCapacity, inputEventCapacity: inputEventCapacity
        )
        try core.transitionHardware(
            epoch: epochFactory(),
            linkState: surface.source == .hardware && surface.connection.isConnected ? .connected : .disconnected,
            at: monotonic()
        )
        surface.hardwareInputPreflight = { [weak self] control, message in try self?.preflight(control, message) }
        surface.hardwareInputCommit = { [weak self] control, message, engine, accepted in
            try self?.commit(control, message, engine, accepted)
        }
    }

    private func refresh() throws {
        guard context != surface.mappingContextRevision || generation != surface.inputEvents
            .generation || source != surface.source else { return }
        var next = core
        try next.transitionHardware(epoch: epochFactory(),
                                    linkState: surface.source == .hardware && surface.connection
                                        .isConnected ? .connected : .disconnected,
                                    profile: try Self.profile(surface, inputEventCapacity: core.inputEventCapacity),
                                    at: monotonic())
        core = next; context = surface.mappingContextRevision; generation = surface.inputEvents
            .generation; source = surface.source
        prepared = nil
        completedFeedbackOrdinals.removeAll()
    }

    private func preflight(_ control: BCRControlID, _ message: MIDIVoiceMessage) throws {
        prepared = nil
        do {
            try refresh()
            guard let descriptor = core.profile.controls
                .first(where: { $0.id == BCRSurfaceControlAdapter.controlID(control) }) else { return }
            let input = ControlHardwareInput(
                expected: core.expected,
                controlID: descriptor.id,
                encoding: descriptor.encoding.rawValue,
                value: control.isContinuous ? .double(Double(message.dataValue)) : .bool(message.isPositiveActivation)
            )
            let now = monotonic()
            _ = try core.validateHardwareInput(input, at: now, writerID: principals.interfaceWriterID)
            prepared = (input, now)
        } catch { diagnostics.append("hardware_input_preflight_failed"); throw error }
    }

    private func commit(
        _ control: BCRControlID,
        _ message: MIDIVoiceMessage,
        _ engine: SurfaceEngine,
        _ accepted: Bool
    ) throws {
        guard let (input, now) = prepared else { return }
        defer { prepared = nil }
        let mapped = engine.configuration.assignment(for: control)?.target.parameterID.flatMap { engine.value(of: $0) }
        var next = core
        _ = try next.recordHardwareInput(input, disposition: accepted ? .accepted : .ignored,
                                         mappedValue: mapped.map(JSONValue.double),
                                         reason: accepted ? nil : "engine_ignored",
                                         at: now, writerID: principals.interfaceWriterID)
        core = next
    }

    /// A read of retained genuine hardware facts; never an input-injection path or a write budget.
    public func execute(_ request: ControlInputEventsRequest, gateway _: MCPApplicationGateway) throws -> JSONValue {
        try refresh()
        return try .encoded(core.inputEvents(expected: request.expected,
                                             afterInputSequence: request.after_input_sequence,
                                             limit: request.limit, at: monotonic()))
    }

    public func execute(_ request: ControlToolRequest, gateway: MCPApplicationGateway) throws -> JSONValue {
        try refresh()
        switch request {
        case .discover: return try .encoded(core.discovery())
        case let .snapshot(instanceID):
            guard instanceID == core.expected.instance_id else { throw ControlContractError("instance_mismatch") }
            return try .encoded(core.snapshot(at: monotonic()))
        case let .events(instanceID, epoch, after, limit):
            return try .encoded(core.events(
                instanceID: instanceID,
                epoch: epoch,
                afterSequence: after,
                limit: limit,
                at: monotonic()
            ))
        case let .input(input):
            _ = try core.validateInput(
                input,
                at: monotonic(),
                writerID: (gateway.authenticatedSurfaceWriterID ?? principals.remoteWriterID)
            )
            throw ControlContractError("permission_denied")
        case let .renew(renew):
            try core.validateRenew(renew, at: monotonic()); throw ControlContractError("unsupported_hold")
        case let .reset(expected, sequence):
            var next = core
            try next.reset(expected: expected, expectedSequence: sequence, epoch: epochFactory(), at: monotonic())
            throw ControlContractError("unsupported_tool")
        case let .feedback(update):
            let now = monotonic()
            try core.validateFeedback(
                update,
                at: now,
                writerID: (gateway.authenticatedSurfaceWriterID ?? principals.remoteWriterID)
            )
            guard permissions.feedback, gateway.permissions.parameterWrite, surface.hardwareOutput == .write,
                  surface.source == .hardware,
                  surface.connection.isConnected else { throw ControlContractError("permission_denied") }
            guard let control = BCRLayout.allControls
                .first(where: { BCRSurfaceControlAdapter.controlID($0) == update.control_id })
            else { throw ControlContractError("unsupported_control") }
            // Shared validation already bounds the value; never trap the provider if it ever loosens.
            let raw: UInt16
            if update.kind == "indicator" {
                raw = update.value.stringValue == "off" ? 0 : update.value.stringValue == "on" ? 127 : 96
            } else {
                guard let number = update.value.finiteNumber, number >= 0, number <= 127,
                      number.rounded() == number else { throw ControlContractError("invalid_value") }
                raw = UInt16(number)
            }
            let writer = gateway.authenticatedSurfaceWriterID ?? principals.remoteWriterID
            let admitted = core.expected
            try gateway.consumeWrites(1)
            feedbackOrdinal &+= 1
            let ordinal = feedbackOrdinal
            let property = FeedbackProperty(control: update.control_id, kind: update.kind)
            var completedEvent: ControlEvent?
            try surface.setHardwareDisplayFeedback(control, rawValue: raw) {
                try self.refresh()
                guard self.core.expected == admitted,
                      self.completedFeedbackOrdinals[property].map({ $0 <= ordinal }) ?? true
                else { throw ControlContractError("delivery_failed") }
                // CAS was consumed at admission before IO. Reentrant input/feedback facts remain canonical.
                let completion = ControlFeedback(expected: admitted, controlID: update.control_id,
                                                 kind: update.kind, value: update.value)
                completedEvent = try self.core.recordFeedback(
                    completion,
                    origin: .remote,
                    at: self.monotonic(),
                    writerID: writer
                )
                self.completedFeedbackOrdinals[property] = ordinal
            }
            guard let event = completedEvent else { throw ControlContractError("delivery_failed") }
            return try .encoded(event)
        }
    }
}
