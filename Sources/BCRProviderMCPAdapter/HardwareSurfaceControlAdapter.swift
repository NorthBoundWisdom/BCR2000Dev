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
    private var core: SurfaceControlSession
    private var context: UInt64
    private var generation: String
    private var source: DeviceSource
    private var prepared: (ControlHardwareInput, Double)?
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

    public static func profile(_ surface: SurfaceSession) -> ControlProfile {
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
        let bytes = (try? encoder.encode(surface.learnedHardwareMap)) ?? Data()
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
        return ControlProfile(id: "bcr2000.hardware", version: "1.4", controls: controls, capabilities: capabilities)
    }

    public static func publishedContract(surface: SurfaceSession) throws -> JSONValue {
        let core = try SurfaceControlSession(
            instanceID: "example.hardware",
            epoch: "discovery-only",
            profile: profile(surface)
        )
        return try .object(["discovery": .encoded(core.discovery()),
                            "tools": .array(SurfaceControlTools.descriptors(source: .hardware)
                                .map { try .encoded($0) }),
                            "excluded_controls": .array(exclusions(surface).map(JSONValue.string)),
                            "hardware_group": .string("unknown")])
    }

    public init(surface: SurfaceSession, instanceID: String, permissions: BCRSurfaceControlAdapter.Permissions,
                principals: SurfaceControlPrincipals = .init(), eventCapacity: Int = 1024,
                monotonic: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) throws
    {
        self.surface = surface; self.permissions = permissions; self.principals = principals; self.monotonic = monotonic
        context = surface.mappingContextRevision; generation = surface.inputEvents.generation; source = surface.source
        core = try SurfaceControlSession(
            instanceID: instanceID,
            epoch: UUID().uuidString,
            profile: Self.profile(surface),
            eventCapacity: eventCapacity
        )
        try core.transitionHardware(
            epoch: UUID().uuidString,
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
        try next.transitionHardware(epoch: UUID().uuidString,
                                    linkState: surface.source == .hardware && surface.connection
                                        .isConnected ? .connected : .disconnected,
                                    profile: Self.profile(surface), at: monotonic())
        core = next; context = surface.mappingContextRevision; generation = surface.inputEvents
            .generation; source = surface.source
        prepared = nil
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
            _ = try core.validateInput(input, at: monotonic(), writerID: principals.remoteWriterID)
            throw ControlContractError("permission_denied")
        case let .renew(renew):
            try core.validateRenew(renew, at: monotonic()); throw ControlContractError("unsupported_hold")
        case let .reset(expected, sequence):
            var next = core
            try next.reset(expected: expected, expectedSequence: sequence, epoch: UUID().uuidString, at: monotonic())
            throw ControlContractError("unsupported_tool")
        case let .feedback(update):
            let now = monotonic()
            try core.validateFeedback(update, at: now, writerID: principals.remoteWriterID)
            guard permissions.feedback, gateway.permissions.parameterWrite, surface.hardwareOutput == .write,
                  surface.source == .hardware,
                  surface.connection.isConnected else { throw ControlContractError("permission_denied") }
            guard let control = BCRLayout.allControls
                .first(where: { BCRSurfaceControlAdapter.controlID($0) == update.control_id })
            else { throw ControlContractError("unsupported_control") }
            let raw: UInt16 = update
                .kind == "indicator" ?
                (update.value.stringValue == "off" ? 0 : update.value.stringValue == "on" ? 127 : 96) :
                UInt16(update.value.finiteNumber!)
            var next = core
            let event = try next.recordFeedback(update, origin: .remote, at: now, writerID: principals.remoteWriterID)
            try gateway.consumeWrites(1)
            try surface.setHardwareDisplayFeedback(control, rawValue: raw)
            core = next
            return try .encoded(event)
        }
    }
}
