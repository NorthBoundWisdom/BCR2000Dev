import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import Foundation
import SurfaceControlContracts
import SurfacePluginContracts

/// Optional software control contract. Neither the Provider 1.0 inventory nor hardware is its source.
@MainActor
public final class BCRSurfaceControlAdapter {
    public struct Permissions: Sendable {
        public var input: Bool
        public var feedback: Bool
        public var reset: Bool
        public init(input: Bool = false, feedback: Bool = false, reset: Bool = false) {
            self.input = input; self.feedback = feedback; self.reset = reset
        }
    }

    private let surface: SurfaceSession
    private let monotonic: @MainActor () -> Double
    private let permissions: Permissions
    private var core: SurfaceControlSession
    private var context: Data
    private var generation: String
    private var handlingRemote = false
    private var inputObserver: UUID?
    private var observationError: ControlContractError?

    public init(surface: SurfaceSession, instanceID: String, permissions: Permissions = .init(),
                eventCapacity: Int = 1024,
                monotonic: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) throws
    {
        self.surface = surface; self.permissions = permissions; self.monotonic = monotonic
        context = try Self.context(surface); generation = surface.inputEvents.generation
        core = try SurfaceControlSession(instanceID: instanceID, epoch: UUID().uuidString,
                                         mappingRevision: UUID().uuidString, profile: Self.profile(surface),
                                         eventCapacity: eventCapacity)
        try seed()
        inputObserver = surface.observeAcceptedInput { [weak self] control, message, mapped, origin in
            self?.observe(control, message: message, mapped: mapped, origin: origin)
        }
    }

    deinit {
        let surface = surface; let token = inputObserver
        Task { @MainActor in if let token { surface.removeAcceptedInputObserver(token) } }
    }

    public static func controlID(_ control: BCRControlID) -> String {
        "\(control.section.rawValue).\(control.row).\(control.index)"
    }

    private static func context(_ surface: SurfaceSession) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(surface.engine.configuration)
    }

    private static func profile(_ surface: SurfaceSession) -> ControlProfile {
        let controls = BCRLayout.allControls.map { control -> ControlDescriptor in
            let assignment = surface.engine.configuration.assignment(for: control)
            let relative = control.isContinuous && assignment?.encoderMode != nil && assignment?
                .encoderMode != .absolute
            let maximum: Double = surface.engine.hardwareMap.midi(for: control)?.kind == .nrpn ? 16383 : 127
            let range = control.isContinuous ? ControlValueRange(
                minimum: relative ? -(maximum + 1) / 2 + 1 : 0,
                maximum: relative ? (maximum + 1) / 2 - 1 : maximum,
                step: 1
            ) : nil
            let mapping = assignment?.target.parameterID.map { ControlMapping(kind: .parameter, id: $0.rawValue) }
            return ControlDescriptor(
                id: controlID(control),
                inputKind: control.isContinuous ? (relative ? .relative : .absolute) : .button,
                encoding: control.isContinuous ? (relative ? .signedDelta : .scalar) : .boolean,
                range: range,
                feedbackRange: control.isContinuous ? .init(minimum: 0, maximum: maximum, step: 1) : nil,
                feedbackKinds: control.isContinuous ? [.value] : [.value, .indicator],
                mapping: mapping
            )
        }
        return ControlProfile(id: "bcr2000.mock", version: "1.0", controls: controls,
                              capabilities: [
                                  "simulation",
                                  "stable_control_ids",
                                  "display_only_feedback",
                                  "explicit_input_permissions"
                              ])
    }

    private func seed() throws {
        var values: [String: JSONValue] = [:]
        for control in BCRLayout.allControls {
            let descriptor = core.profile.controls.first { $0.id == Self.controlID(control) }!
            let raw = surface.mock.inputDataValues[control]
            switch descriptor.encoding {
            case .boolean: if let raw { values[descriptor.id] = .bool(raw > 0) }
            case .scalar: if let raw { values[descriptor.id] = .double(Double(raw)) }
            case .signedDelta: break // A relative tick is an event, not an absolute initial position.
            }
        }
        try core.seedInputs(values, at: monotonic())
    }

    private func refresh() throws {
        let next = try Self.context(surface)
        if next != context || generation != surface.inputEvents.generation {
            try core.reset(
                expected: core.expected,
                expectedSequence: core.discovery().latest_sequence,
                epoch: UUID().uuidString,
                mappingRevision: UUID().uuidString,
                profile: Self.profile(surface),
                at: monotonic()
            )
            try seed()
            context = next; generation = surface.inputEvents.generation; observationError = nil
        }
    }

    public func discovery() throws -> ControlDiscovery { try refresh(); return core.discovery() }
    private func requireMock() throws {
        guard surface.source == .mock,
              !surface.diagnosticReadbackActive else { throw ControlContractError("unsupported_source") }
        if let observationError { throw observationError }
    }

    private func consume(_ gateway: MCPApplicationGateway) throws {
        do { try gateway.consumeWrites(1) }
        catch { throw ControlContractError("rate_limited") }
    }

    private func control(_ id: String) throws -> BCRControlID {
        guard let value = BCRLayout.allControls.first(where: { Self.controlID($0) == id }) else {
            throw ControlContractError("unsupported_control")
        }
        return value
    }

    private func observe(
        _ control: BCRControlID,
        message: MIDIVoiceMessage,
        mapped: Double?,
        origin: SurfaceWriteOrigin
    ) {
        guard !handlingRemote, surface.source == .mock else { return }
        do {
            try refresh()
            let descriptor = core.profile.controls.first { $0.id == Self.controlID(control) }!
            let mode = surface.engine.configuration.assignment(for: control)?.encoderMode ?? .absolute
            let value: JSONValue = control.isContinuous ? (mode == .absolute ? .double(Double(message.dataValue)) :
                .double(Double(mode.delta(value: message.dataValue, maximum: message.maximumDataValue)))) :
                .bool(message.isPositiveActivation)
            let input = ControlInput(
                expected: core.expected,
                expectedSequence: core.discovery().latest_sequence,
                controlID: descriptor.id,
                encoding: descriptor.encoding.rawValue,
                value: value
            )
            let now = monotonic()
            let prior = try core.snapshot(at: now).inputs[descriptor.id]
            let changed = descriptor.encoding == .signedDelta || prior != value
            try core.recordInput(
                input,
                disposition: changed ? .accepted : .ignored,
                mappedValue: mapped.map(JSONValue.double),
                reason: changed ? nil : "no_change",
                origin: origin == .agent ? .remote : .interface,
                at: now
            )
        } catch let error as ControlContractError { observationError = error }
        catch { observationError = ControlContractError("invalid_state") }
    }

    public func execute(_ request: ControlToolRequest, gateway: MCPApplicationGateway) throws -> JSONValue {
        try refresh()
        switch request {
        case .discover:
            try requireMock(); return try .encoded(core.discovery())
        case let .snapshot(instanceID):
            guard instanceID == core.expected.instance_id else { throw ControlContractError("instance_mismatch") }
            try requireMock(); return try .encoded(core.snapshot(at: monotonic()))
        case let .events(instanceID, epoch, after, limit):
            try requireMock()
            return try .encoded(core.events(
                instanceID: instanceID,
                epoch: epoch,
                afterSequence: after,
                limit: limit,
                at: monotonic()
            ))
        case let .input(input):
            try requireMock()
            guard !handlingRemote else { throw ControlContractError("operation_in_progress") }
            guard permissions.input, gateway.permissions.parameterWrite, gateway.permissions.deviceControl else {
                throw ControlContractError("permission_denied")
            }
            let now = monotonic(); let descriptor = try core.validateInput(input, at: now)
            let control = try control(input.control_id)
            guard let id = surface.engine.configuration.assignment(for: control)?.target.parameterID,
                  let definition = surface.engine.configuration.parameter(id), definition.agentWritable,
                  !surface.isMCPProtectedParameter(id) else { throw ControlContractError("permission_denied") }
            try consume(gateway)
            if descriptor.encoding != .signedDelta,
               try core.snapshot(at: now).inputs[input.control_id] == input.value
            {
                return try .encoded(core.recordInput(input, disposition: .ignored,
                                                     mappedValue: surface.engine.value(of: id).map(JSONValue.double),
                                                     reason: "no_change", origin: .remote, at: now))
            }
            let before = surface.engine.state(of: control).eventCount
            handlingRemote = true
            defer { handlingRemote = false }
            surface.withWriteOrigin(.agent) {
                switch descriptor.encoding {
                case .boolean:
                    if input.value.boolValue! { surface.press(control) } else { surface.release(control) }
                case .signedDelta: surface.turn(control, by: Int(input.value.finiteNumber!))
                case .scalar:
                    let current = surface.engine.hardwareMap.midi(for: control)?.kind == .nrpn ?
                        Int(surface.mock.rawValues[control] ?? 0) : Int(surface.mock.value(of: control))
                    surface.turn(control, by: Int(input.value.finiteNumber!) - current)
                }
            }
            try refresh()
            try core.validateExpected(input.expected)
            let accepted = before != surface.engine.state(of: control).eventCount
            return try .encoded(core.recordInput(input, disposition: accepted ? .accepted : .ignored,
                                                 mappedValue: surface.engine.value(of: id).map(JSONValue.double),
                                                 reason: accepted ? nil : "no_change",
                                                 origin: .remote, at: now))
        case let .feedback(update):
            try requireMock()
            guard !handlingRemote else { throw ControlContractError("operation_in_progress") }
            guard permissions.feedback,
                  gateway.permissions.parameterWrite else { throw ControlContractError("permission_denied") }
            let now = monotonic(); try core.validateFeedback(update, at: now)
            let control = try control(update.control_id)
            let raw: UInt16
            if update
                .kind ==
                "indicator"
            {
                raw = update.value.stringValue == "off" ? 0 : (update.value.stringValue == "on" ? 127 : 96)
            } else if let value = update.value.boolValue { raw = value ? 127 : 0 }
            else { raw = UInt16(update.value.finiteNumber!) }
            var next = core
            let event = try next.recordFeedback(update, origin: .remote, at: now)
            try consume(gateway)
            handlingRemote = true
            defer { handlingRemote = false }
            try surface.setSimulationDisplayFeedback(control, rawValue: raw)
            core = next
            return try .encoded(event)
        case let .reset(expected, expectedSequence):
            try requireMock()
            guard !handlingRemote else { throw ControlContractError("operation_in_progress") }
            guard permissions.reset, gateway.permissions.parameterWrite, gateway.permissions.simulationControl else {
                throw ControlContractError("permission_denied")
            }
            var next = core
            try next.reset(
                expected: expected,
                expectedSequence: expectedSequence,
                epoch: UUID().uuidString,
                mappingRevision: UUID().uuidString,
                at: monotonic()
            )
            try consume(gateway)
            handlingRemote = true
            defer { handlingRemote = false }
            try surface.clearSimulationDisplayFeedback()
            try surface.resetSimulationInputs()
            core = next; context = try Self.context(surface); generation = surface.inputEvents.generation
            observationError = nil
            try seed()
            return try .encoded(core.discovery())
        }
    }
}
