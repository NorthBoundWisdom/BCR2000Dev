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

    /// Schedules `action` after `delay` seconds on the main actor and returns its cancellation.
    public typealias HoldScheduler = @MainActor (_ delay: Double, _ action: @escaping @MainActor () -> Void)
        -> @MainActor () -> Void

    /// Upper bound for a button lease (`hold.max_hold_s`). A consumer renews well within it.
    public static let maximumButtonHoldSeconds = 5.0

    /// Timer slack requested from the system for a lease deadline. Without an explicit tolerance the
    /// runtime may coalesce a sleep by a fraction of its duration, which would grow with `hold_s`.
    public static let holdTimerTolerance: Duration = .milliseconds(2)

    /// Sleeps on the suspending clock (the same time base as `systemUptime`) with a fixed small
    /// tolerance, then runs on the main actor. Expiry lag is therefore the tolerance plus the time
    /// the main actor needs to finish the jobs already queued ahead of the timer.
    public static let defaultHoldScheduler: HoldScheduler = { delay, action in
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(max(0, delay)) + .milliseconds(1),
                                     tolerance: holdTimerTolerance, clock: .suspending)
            } catch { return }
            action()
        }
        return { task.cancel() }
    }

    private let surface: SurfaceSession
    private let monotonic: @MainActor () -> Double
    private let permissions: Permissions
    private let diagnose: @MainActor (Diagnostic) -> Void
    private let scheduler: HoldScheduler
    /// When false, due leases are processed only through `processHoldExpiries()` (in-process fault probes).
    private let automaticHoldExpiry: Bool
    private var cancelHoldTimer: (@MainActor () -> Void)?
    /// Leases revoked while the Mock was not the active source. Their rest values are applied
    /// before the Mock is reseeded, so a revoked button never stays held (deadman stays safe).
    private var deferredRests: [ControlHoldExpiry] = []
    public typealias WriteLimits = ControlWriteLimits
    public let principals: SurfaceControlPrincipals
    private let writeLimits: ControlWriteLimits?
    private enum WriteCategory: Hashable { case input, feedback, renew, admin }
    private var budgetWindow: Double?
    private var budgetUsed: [WriteCategory: Int] = [:]
    private var core: SurfaceControlSession
    private var outputEnableParameter: ParameterID?
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
                diagnostic: @escaping @MainActor (Diagnostic) -> Void = { _ in },
                holdScheduler: @escaping HoldScheduler = BCRSurfaceControlAdapter.defaultHoldScheduler,
                automaticHoldExpiry: Bool = true,
                principals: SurfaceControlPrincipals = .init(), writeLimits: ControlWriteLimits? = nil) throws
    {
        self.principals = principals; self.writeLimits = writeLimits
        self.surface = surface; self.permissions = permissions; self.monotonic = monotonic
        diagnose = diagnostic; scheduler = holdScheduler; self.automaticHoldExpiry = automaticHoldExpiry
        contextRevision = surface.mappingContextRevision; generation = surface.inputEvents.generation
        outputEnableParameter = surface.outputEnableParameter
        core = try Self.seeded(
            SurfaceControlSession(
                instanceID: instanceID,
                epoch: UUID().uuidString,
                profile: Self.profile(surface, writeLimits: writeLimits),
                eventCapacity: eventCapacity, writeLimits: writeLimits
            ),
            surface: surface,
            at: monotonic()
        )
        inputObserver = surface.observeAcceptedInput { [weak self] control, message, mapped, origin in
            self?.observe(control, message: message, mapped: mapped, origin: origin)
        }
    }

    deinit {
        let surface = surface; let token = inputObserver; let cancel = cancelHoldTimer
        Task { @MainActor in
            cancel?()
            if let token { surface.removeAcceptedInputObserver(token) }
        }
    }

    public static func controlID(_ control: BCRControlID) -> String {
        "\(control.section.rawValue).\(control.row).\(control.index)"
    }

    /// Static published description of a configuration: discovery (profile, capabilities, mapping
    /// revision) plus the tool descriptors. The instance and epoch are placeholders; a live
    /// instance is always pinned through `surface_control_discover`. Opens no device.
    public static func publishedContract(surface: SurfaceSession, instanceID: String = "example.simulation",
                                         epoch: String = "discovery-only",
                                         writeLimits: ControlWriteLimits? = nil) throws -> JSONValue
    {
        let session = try SurfaceControlSession(
            instanceID: instanceID,
            epoch: epoch,
            profile: profile(surface, writeLimits: writeLimits), writeLimits: writeLimits
        )
        return try .object(["discovery": .encoded(session.discovery()),
                            "tools": .array(SurfaceControlTools.descriptors.map { try .encoded($0) })])
    }

    /// Host error codes pass through unchanged; only unknown errors become `invalid_argument`.
    public static func failureCode(_ error: any Error) -> String {
        (error as? ControlContractError)?.code ?? (error as? ProviderDomainError)?.code ?? "invalid_argument"
    }

    private static func profile(_ surface: SurfaceSession, writeLimits: ControlWriteLimits? = nil) -> ControlProfile {
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
            let acceptsInput = assignment?.target.parameterID.flatMap { id in
                surface.engine.configuration.parameter(id)
                    .map { $0.agentWritable && !surface.isMCPProtectedParameter(id) }
            } ?? false
            return ControlDescriptor(
                id: controlID(control),
                inputKind: control.isContinuous ? (relative ? .relative : .absolute) : .button,
                encoding: control.isContinuous ? (relative ? .signedDelta : .scalar) : .boolean,
                range: range,
                feedbackRange: control.isContinuous ? .init(minimum: 0, maximum: maximum, step: 1) : nil,
                // A BCR button has one LED display slot, so it declares only the semantic indicator.
                feedbackKinds: control.isContinuous ? [.value] : [.indicator],
                mapping: mapping,
                // A lease is truthful only when release restores the accepted input's effect.
                hold: !control.isContinuous && acceptsInput && assignment?.buttonBehavior == .momentary ?
                    ControlHold(restValue: .bool(false), maxHoldSeconds: maximumButtonHoldSeconds) : nil,
                acceptsInput: acceptsInput
            )
        }
        var capabilities = ["simulation", "controls.stable_ids", "feedback.unsequenced", "controls.input_declared",
                            "input.independent_sequence", "events.writer_id"]
        if writeLimits != nil { capabilities.append("writes.independent_limits") }
        let inputs = Set(controls.map(\.input_kind))
        for kind in [ControlInputKind.absolute, .relative, .button] where inputs.contains(kind) {
            capabilities.append("input." + kind.rawValue)
        }
        if controls.contains(where: { $0.hold != nil }) { capabilities.append("input.hold") }
        let feedback = Set(controls.flatMap(\.feedback_kinds))
        for kind in [ControlFeedbackKind.value, .indicator] where feedback.contains(kind) {
            capabilities.append("feedback." + kind.rawValue)
        }
        capabilities += ["x.bcr.display_only_feedback", "x.bcr.explicit_input_permissions",
                         "x.bcr.indicator_blink_static"]
        return ControlProfile(id: "bcr2000.mock", version: "1.3", controls: controls, capabilities: capabilities)
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
            generation != surface.inputEvents.generation || outputEnableParameter != surface.outputEnableParameter
        else { return }
        let now = monotonic()
        var next = core
        // Every lease is revoked with the old context. Due ones are closed in the discarded journal so
        // the reset clock checks still apply; all held Mock controls return to rest before reseeding.
        let leases = core.dueHoldExpiries(at: .infinity)
        for lease in leases
            where lease.deadline <= now
        { try next.recordHoldExpiry(
            controlID: lease.controlID,
            at: now,
            writerID: principals.systemWriterID
        ) }
        try next.reset(
            expected: next.expected,
            expectedSequence: next.discovery().latest_sequence,
            epoch: UUID().uuidString,
            profile: Self.profile(surface, writeLimits: writeLimits),
            at: now
        )
        if surface.source == .mock {
            for lease in deferredRests + leases { try applyRest(lease) }
            deferredRests.removeAll()
        } else {
            deferredRests += leases
        }
        next = try Self.seeded(next, surface: surface, at: now)
        core = next
        contextRevision = surface.mappingContextRevision; generation = surface.inputEvents.generation
        outputEnableParameter = surface.outputEnableParameter
        pendingRotation = nil
        rescheduleHoldTimer()
    }

    /// Applies a lease rest value to the Mock through the ordinary simulated input path. Mock only.
    private func applyRest(_ lease: ControlHoldExpiry) throws {
        let control = try control(lease.controlID)
        guard surface.source == .mock else { throw ControlContractError("unsupported_source") }
        let wasHandling = handlingRemote
        handlingRemote = true
        defer { handlingRemote = wasHandling }
        surface.withWriteOrigin(.agent) {
            if let pressed = lease.restValue.boolValue {
                if pressed { surface.press(control) } else { surface.release(control) }
            } else if let raw = lease.restValue.finiteNumber {
                surface.simulateAbsoluteInput(control, rawValue: UInt16(raw))
            }
        }
    }

    private func mappedValue(_ control: BCRControlID) -> JSONValue? {
        surface.engine.configuration.assignment(for: control)?.target.parameterID
            .flatMap { surface.engine.value(of: $0) }.map(JSONValue.double)
    }

    /// Processes every lease due at the current host time: rest value to the Mock first, then the
    /// journal event. This is what the scheduler runs; requests call it before doing anything else.
    @discardableResult
    public func processHoldExpiries() throws -> [ControlEvent] {
        try refresh()
        let now = monotonic()
        let due = core.dueHoldExpiries(at: now)
        var events: [ControlEvent] = []
        // Reserve/check every required counter and trusted identity on a copy before any host effect.
        var preflight = core
        for lease in due {
            try preflight.recordHoldExpiry(controlID: lease.controlID, at: now, writerID: principals.systemWriterID)
        }
        for lease in due {
            try applyRest(lease)
            do {
                try events.append(core.recordHoldExpiry(controlID: lease.controlID,
                                                        mappedValue: mappedValue(control(lease.controlID)), at: now,
                                                        writerID: principals.systemWriterID))
            } catch { failClosed("hold_expiry_record_failed", error: error); throw error }
        }
        rescheduleHoldTimer()
        return events
    }

    /// Request preflight: releases leases that are already due. Failures stay fail closed through
    /// the ordinary path (the following surface call reports them); other tools are unaffected.
    public func processDueHoldsBeforeRequest() {
        guard automaticHoldExpiry, !handlingRemote, surface.source == .mock,
              let deadline = core.nextHoldDeadline, deadline <= monotonic() else { return }
        do { try processHoldExpiries() } catch {
            if pendingRotation == nil { failClosed("hold_preflight_failed", error: error) }
        }
    }

    /// The earliest active lease deadline (host monotonic seconds), if any.
    public var nextHoldDeadline: Double? { core.nextHoldDeadline }

    private func rescheduleHoldTimer() {
        cancelHoldTimer?(); cancelHoldTimer = nil
        guard automaticHoldExpiry, let deadline = core.nextHoldDeadline else { return }
        cancelHoldTimer = scheduler(max(0, deadline - monotonic())) { [weak self] in
            guard let self else { return }
            self.cancelHoldTimer = nil
            do { try self.processHoldExpiries() } catch {
                if self.pendingRotation == nil { self.failClosed("hold_timer_failed", error: error) }
                self.rescheduleHoldTimer()
            }
        }
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

    /// CLI syntax only; the public budget value/validation belongs to the shared contract.
    nonisolated public static func parseWriteLimits(_ raw: String) throws -> ControlWriteLimits {
        var values: [String: Int] = [:]
        for pair in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2, ["input", "feedback", "renew", "admin"].contains(String(parts[0])),
                  values[String(parts[0])] == nil, !parts[1].isEmpty,
                  parts[1].utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let value = Int(parts[1]), (1 ... 10000).contains(value)
            else {
                throw ControlContractError("invalid_argument")
            }
            values[String(parts[0])] = value
        }
        guard values.count == 4 else { throw ControlContractError("invalid_argument") }
        let limits = ControlWriteLimits(inputPerWindow: values["input"]!, feedbackPerWindow: values["feedback"]!,
                                        renewPerWindow: values["renew"]!, adminPerWindow: values["admin"]!)
        try limits.validate()
        return limits
    }

    private func consume(_ gateway: MCPApplicationGateway, category: WriteCategory, at now: Double) throws {
        guard let limits = writeLimits else {
            do { try gateway.consumeWrites(1) }
            catch { throw ControlContractError("rate_limited") }
            return
        }
        guard now.isFinite, budgetWindow.map({ now >= $0 }) ?? true else {
            throw ControlContractError("invalid_time")
        }
        let maximum: Int
        switch category {
        case .input: maximum = limits.input_per_window
        case .feedback: maximum = limits.feedback_per_window
        case .renew: maximum = limits.renew_per_window
        case .admin: maximum = limits.admin_per_window
        }
        if budgetWindow == nil || now - budgetWindow! >= Double(limits.window_s) {
            budgetWindow = now; budgetUsed.removeAll()
        }
        guard budgetUsed[category, default: 0] < maximum else { throw ControlContractError("rate_limited") }
        budgetUsed[category, default: 0] += 1
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
        // Only local interface input is recorded. Any other writer (for example a legacy Provider
        // mock input) is not a fenced surface_control input: revoke the context instead.
        guard origin == .software else { failClosed("unexpected_input_origin_" + origin.rawValue); return }
        do {
            try refresh()
            if automaticHoldExpiry, !core.dueHoldExpiries(at: monotonic()).isEmpty {
                // Due leases are recorded before the operator input that follows them.
                handlingRemote = true
                defer { handlingRemote = false }
                try processHoldExpiries()
            }
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
            let changed = !core.isUnchanged(input)
            try core.recordInput(
                input,
                disposition: changed ? .accepted : .ignored,
                mappedValue: mapped.map(JSONValue.double),
                reason: changed ? nil : "no_change",
                origin: .interface,
                at: now, writerID: principals.interfaceWriterID
            )
            rescheduleHoldTimer()
        } catch { failClosed("observation_failed", error: error) }
    }

    /// Records the outcome of an engine change that has already happened. A failure here cannot
    /// be undone, so the context is revoked (new epoch on the next call) before reporting it.
    private func commitInput(_ input: ControlInput, disposition: ControlDisposition, mappedValue: JSONValue?,
                             reason: String?, at now: Double) throws -> JSONValue
    {
        do {
            let event = try core.recordInput(input, disposition: disposition, mappedValue: mappedValue,
                                             reason: reason, origin: .remote, at: now,
                                             writerID: principals.remoteWriterID)
            rescheduleHoldTimer()
            return try .encoded(event)
        } catch { failClosed("input_record_failed", error: error); throw error }
    }

    public func execute(_ request: ControlToolRequest, gateway: MCPApplicationGateway) throws -> JSONValue {
        try refresh()
        if automaticHoldExpiry, !handlingRemote, surface.source == .mock { try processHoldExpiries() }
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
            let now = monotonic(); let descriptor = try core.validateInput(
                input,
                at: now,
                writerID: principals.remoteWriterID
            )
            let control = try control(input.control_id)
            guard let id = surface.engine.configuration.assignment(for: control)?.target.parameterID,
                  let definition = surface.engine.configuration.parameter(id), definition.agentWritable,
                  !surface.isMCPProtectedParameter(id) else { throw ControlContractError("permission_denied") }
            let unchanged = core.isUnchanged(input)
            try consume(gateway, category: .input, at: now)
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
            let now = monotonic(); try core.validateFeedback(update, at: now, writerID: principals.remoteWriterID)
            let control = try control(update.control_id)
            let raw: UInt16
            if update.kind == "indicator" {
                // Static presentation: BCR button LEDs do not flash, so blink is shown as 96.
                raw = update.value.stringValue == "off" ? 0 : (update.value.stringValue == "on" ? 127 : 96)
            } else if let value = update.value.boolValue { raw = value ? 127 : 0 }
            else { raw = UInt16(update.value.finiteNumber!) }
            try surface.validateSimulationDisplayFeedback(control, rawValue: raw)
            var next = core
            let event = try next.recordFeedback(update, origin: .remote, at: now, writerID: principals.remoteWriterID)
            let result = try JSONValue.encoded(event)
            try consume(gateway, category: .feedback, at: now)
            handlingRemote = true
            defer { handlingRemote = false }
            try surface.setSimulationDisplayFeedback(control, rawValue: raw)
            core = next
            return result
        case let .renew(request):
            try requireMock()
            guard !handlingRemote else { throw ControlContractError("operation_in_progress") }
            guard permissions.input, gateway.permissions.parameterWrite, gateway.permissions.deviceControl else {
                throw ControlContractError("permission_denied")
            }
            let now = monotonic()
            try core.validateRenew(request, at: now)
            try consume(gateway, category: .renew, at: now)
            let result = try core.renew(request, at: now)
            rescheduleHoldTimer()
            return try .encoded(result)
        case let .reset(expected, expectedSequence):
            try requireMock()
            guard !handlingRemote else { throw ControlContractError("operation_in_progress") }
            guard permissions.reset, gateway.permissions.parameterWrite, gateway.permissions.simulationControl else {
                throw ControlContractError("permission_denied")
            }
            let now = monotonic()
            var next = core
            try next.reset(expected: expected, expectedSequence: expectedSequence, epoch: UUID().uuidString, at: now)
            try surface.validateSimulationReset()
            try consume(gateway, category: .admin, at: now)
            handlingRemote = true
            defer { handlingRemote = false }
            // Session side first; it validates before its first change. The core commits last.
            try surface.resetSimulationContext()
            do { next = try Self.seeded(next, surface: surface, at: now) }
            catch { failClosed("reset_seed_failed", error: error); throw error }
            core = next
            contextRevision = surface.mappingContextRevision; generation = surface.inputEvents.generation
            outputEnableParameter = surface.outputEnableParameter
            pendingRotation = nil
            rescheduleHoldTimer()
            return try .encoded(core.discovery())
        }
    }
}
