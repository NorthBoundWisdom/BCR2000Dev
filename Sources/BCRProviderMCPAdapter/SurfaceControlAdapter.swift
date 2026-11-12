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

    /// A fail-closed observation or recording problem. The adapter changes epoch on the next
    /// call instead of keeping a sticky error, so discovery recovers once the cause is gone.
    public struct Diagnostic: Equatable, Sendable {
        public let reason: String
        public let code: String
        public init(reason: String, code: String) { self.reason = reason; self.code = code }
    }

    private let surface: SurfaceSession
    private let monotonic: @MainActor () -> Double
    private let permissions: Permissions
    private let diagnose: @MainActor (Diagnostic) -> Void
    private var core: SurfaceControlSession
    private var contextRevision: UInt64
    private var generation: String
    private var handlingRemote = false
    private var inputObserver: UUID?
    private var pendingRotation: String?
    public private(set) var diagnostics: [Diagnostic] = []
    public private(set) var diagnosticCount = 0

    public init(surface: SurfaceSession, instanceID: String, permissions: Permissions = .init(),
                eventCapacity: Int = 1024,
                monotonic: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
                diagnostic: @escaping @MainActor (Diagnostic) -> Void = { _ in }) throws
    {
        self.surface = surface; self.permissions = permissions; self.monotonic = monotonic
        diagnose = diagnostic
        contextRevision = surface.mappingContextRevision; generation = surface.inputEvents.generation
        core = try Self.seeded(
            SurfaceControlSession(instanceID: instanceID, epoch: UUID().uuidString,
                                  mappingRevision: UUID().uuidString, profile: Self.profile(surface),
                                  eventCapacity: eventCapacity),
            surface: surface,
            at: monotonic()
        )
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

    /// Host error codes pass through unchanged; only unknown errors become `invalid_argument`.
    public static func failureCode(_ error: any Error) -> String {
        (error as? ControlContractError)?.code ?? (error as? ProviderDomainError)?.code ?? "invalid_argument"
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
                // A BCR button has one LED display slot, so it declares only the semantic indicator.
                feedbackKinds: control.isContinuous ? [.value] : [.indicator],
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

    private static func seeded(_ session: SurfaceControlSession, surface: SurfaceSession,
                               at time: Double) throws -> SurfaceControlSession
    {
        var session = session
        var values: [String: JSONValue] = [:]
        for control in BCRLayout.allControls {
            let descriptor = session.profile.controls.first { $0.id == Self.controlID(control) }!
            let raw = surface.mock.inputDataValues[control]
            switch descriptor.encoding {
            case .boolean: if let raw { values[descriptor.id] = .bool(raw > 0) }
            case .scalar: if let raw { values[descriptor.id] = .double(Double(raw)) }
            case .signedDelta: break // A relative tick is an event, not an absolute initial position.
            }
        }
        try session.seedInputs(values, at: time)
        return session
    }

    /// Changes epoch when the mapping context, the legacy input generation, or a fail-closed
    /// diagnostic requires it. The new session is built on a copy and committed only when complete.
    private func refresh() throws {
        guard pendingRotation != nil || contextRevision != surface.mappingContextRevision ||
            generation != surface.inputEvents.generation else { return }
        let now = monotonic()
        var next = core
        try next.reset(
            expected: core.expected,
            expectedSequence: core.discovery().latest_sequence,
            epoch: UUID().uuidString,
            mappingRevision: UUID().uuidString,
            profile: Self.profile(surface),
            at: now
        )
        next = try Self.seeded(next, surface: surface, at: now)
        core = next
        contextRevision = surface.mappingContextRevision; generation = surface.inputEvents.generation
        pendingRotation = nil
    }

    private func failClosed(_ reason: String, error: (any Error)? = nil) {
        let diagnostic = Diagnostic(reason: reason, code: error.map(Self.failureCode) ?? "invalid_state")
        pendingRotation = reason
        diagnosticCount += 1
        diagnostics.append(diagnostic)
        if diagnostics.count > 64 { diagnostics.removeFirst(diagnostics.count - 64) }
        diagnose(diagnostic)
    }

    public func discovery() throws -> ControlDiscovery { try refresh(); return core.discovery() }
    private func requireMock() throws {
        guard surface.source == .mock,
              !surface.diagnosticReadbackActive else { throw ControlContractError("unsupported_source") }
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

    /// Numeric representation (`.number` vs `.double`) does not make an input different.
    private static func sameInput(_ lhs: JSONValue?, _ rhs: JSONValue) -> Bool {
        guard let lhs else { return false }
        if let left = lhs.finiteNumber, let right = rhs.finiteNumber { return left == right }
        return lhs == rhs
    }

    private func observe(
        _ control: BCRControlID,
        message: MIDIVoiceMessage,
        mapped: Double?,
        origin: SurfaceWriteOrigin
    ) {
        guard !handlingRemote, surface.source == .mock else { return }
        // Only local interface input is recorded. Any other writer (for example a legacy Provider
        // mock input) is not a fenced surface_control input: revoke the context instead.
        guard origin == .software else { failClosed("unexpected_input_origin_" + origin.rawValue); return }
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
            let changed = descriptor.encoding == .signedDelta || !Self.sameInput(prior, value)
            try core.recordInput(
                input,
                disposition: changed ? .accepted : .ignored,
                mappedValue: mapped.map(JSONValue.double),
                reason: changed ? nil : "no_change",
                origin: .interface,
                at: now
            )
        } catch { failClosed("observation_failed", error: error) }
    }

    /// Records the outcome of an engine change that has already happened. A failure here cannot
    /// be undone, so the context is revoked (new epoch on the next call) before reporting it.
    private func commitInput(_ input: ControlInput, disposition: ControlDisposition, mappedValue: JSONValue?,
                             reason: String?, at now: Double) throws -> JSONValue
    {
        do {
            let event = try core.recordInput(input, disposition: disposition, mappedValue: mappedValue,
                                             reason: reason, origin: .remote, at: now)
            return try .encoded(event)
        } catch { failClosed("input_record_failed", error: error); throw error }
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
            // Every fallible check precedes the write budget and the first engine change.
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
            let prior = try core.snapshot(at: now).inputs[input.control_id]
            let unchanged = descriptor.encoding != .signedDelta && Self.sameInput(prior, input.value)
            try consume(gateway)
            if unchanged {
                return try commitInput(input, disposition: .ignored,
                                       mappedValue: surface.engine.value(of: id).map(JSONValue.double),
                                       reason: "no_change", at: now)
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
                    // The requested position, not a delta from the (possibly overlaid) display.
                    surface.simulateAbsoluteInput(control, rawValue: UInt16(input.value.finiteNumber!))
                }
            }
            let accepted = before != surface.engine.state(of: control).eventCount
            return try commitInput(input, disposition: accepted ? .accepted : .ignored,
                                   mappedValue: surface.engine.value(of: id).map(JSONValue.double),
                                   reason: accepted ? nil : "no_change", at: now)
        case let .feedback(update):
            try requireMock()
            guard !handlingRemote else { throw ControlContractError("operation_in_progress") }
            guard permissions.feedback,
                  gateway.permissions.parameterWrite else { throw ControlContractError("permission_denied") }
            let now = monotonic(); try core.validateFeedback(update, at: now)
            let control = try control(update.control_id)
            let raw: UInt16
            if update.kind == "indicator" {
                // Static presentation: BCR button LEDs do not flash, so blink is shown as 96.
                raw = update.value.stringValue == "off" ? 0 : (update.value.stringValue == "on" ? 127 : 96)
            } else if let value = update.value.boolValue { raw = value ? 127 : 0 }
            else { raw = UInt16(update.value.finiteNumber!) }
            try surface.validateSimulationDisplayFeedback(control, rawValue: raw)
            var next = core
            let event = try next.recordFeedback(update, origin: .remote, at: now)
            let result = try JSONValue.encoded(event)
            try consume(gateway)
            handlingRemote = true
            defer { handlingRemote = false }
            try surface.setSimulationDisplayFeedback(control, rawValue: raw)
            core = next
            return result
        case let .reset(expected, expectedSequence):
            try requireMock()
            guard !handlingRemote else { throw ControlContractError("operation_in_progress") }
            guard permissions.reset, gateway.permissions.parameterWrite, gateway.permissions.simulationControl else {
                throw ControlContractError("permission_denied")
            }
            let now = monotonic()
            var next = core
            try next.reset(
                expected: expected,
                expectedSequence: expectedSequence,
                epoch: UUID().uuidString,
                mappingRevision: UUID().uuidString,
                at: now
            )
            try surface.validateSimulationReset()
            try consume(gateway)
            handlingRemote = true
            defer { handlingRemote = false }
            // Session side first; it validates before its first change. The core commits last.
            try surface.resetSimulationContext()
            do { next = try Self.seeded(next, surface: surface, at: now) }
            catch { failClosed("reset_seed_failed", error: error); throw error }
            core = next
            contextRevision = surface.mappingContextRevision; generation = surface.inputEvents.generation
            pendingRotation = nil
            return try .encoded(core.discovery())
        }
    }
}
