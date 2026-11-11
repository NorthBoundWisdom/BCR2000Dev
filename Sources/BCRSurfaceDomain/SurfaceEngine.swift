import BCRFoundation
import Foundation
import struct SurfacePluginContracts.ActionReference
import struct SurfacePluginContracts.IndicatorID

/// What the software believes one physical control currently shows.
public struct SurfaceControlState: Equatable, Sendable {
    public var rawValue: UInt16 = 0
    public var value: UInt8 = 0
    public var lastInput: UInt8?
    public var lastOutput: UInt8?
    public var lastDirection: MIDIObservationDirection?
    public var eventCount = 0

    public init() {}
}

public enum LEDFeedbackSource: String, Codable, Equatable, Sendable {
    case target, actual
}

public enum MIDIObservationDirection: String, Equatable, Sendable {
    case input
    case output
}

public enum SurfaceEffect: Equatable, Sendable {
    /// Feedback to write to the device (LED ring / button LED).
    case send(MIDIVoiceMessage)
    /// Legacy-only enum case retained for source-compatible pattern matching (workspace D8).
    case triggerAgent(AgentSlotID)
    case triggerAction(ActionReference)
    case pageChanged
    case programsChanged
    case learned(BCRControlID, MIDIControlID)
    case learnRejected(BCRControlID, HardwareBindingError)
    /// Input from a MIDI identity that no physical control is bound to.
    case unmappedInput(MIDIControlID)
}

/// Pure, testable bidirectional sync between a device's controls and software parameters.
///
/// Software parameters are the source of truth. Device input moves a parameter and the engine
/// writes the result to every *other* control bound to it; software edits are written to all bound
/// controls. Button LEDs are always owned by software.
public struct SurfaceEngine: Sendable {
    public private(set) var hardwareMap: HardwareMap
    public private(set) var configuration: SurfaceConfiguration
    public private(set) var parameterValues: [ParameterID: Double]
    public private(set) var controls: [BCRControlID: SurfaceControlState] = [:]
    /// While set, the next device input is learned as this control's MIDI identity.
    public private(set) var learnTarget: BCRControlID?
    public private(set) var actualFeedbackValues: [ParameterID: Double] = [:]
    public private(set) var ledFeedbackSource: LEDFeedbackSource = .target
    public private(set) var indicatorFeedback: [IndicatorID: UInt8] = [:]
    public private(set) var pluginBindings: SurfacePluginBindings

    public var recordFeedbackWhenGenerated = true
    public var echoWindow: TimeInterval = 0.18
    public var triggerDebounce: TimeInterval = 0.25

    private var recentFeedback: [MIDIControlID: (value: UInt16, sentAt: Date)] = [:]
    private struct IncrementRemainder: Sendable { let parameter: ParameterID; let anchor: Double; let value: Double }
    private var incrementRemainders: [BCRControlID: IncrementRemainder] = [:]
    private struct AbsoluteInput: Sendable { var logical: Double; var reference: Double; let maximum: UInt16 }
    private var absoluteInputs: [BCRControlID: AbsoluteInput] = [:]
    private var lastTrigger: [BCRControlID: Date] = [:]

    public init(hardwareMap: HardwareMap, configuration: SurfaceConfiguration,
                pluginBindings: SurfacePluginBindings = .init())
    {
        self.hardwareMap = hardwareMap
        self.configuration = configuration
        self.pluginBindings = pluginBindings
        parameterValues = Dictionary(
            uniqueKeysWithValues: configuration.parameters.map { ($0.id, $0.clamp($0.defaultValue)) }
        )
    }

    public mutating func noteFeedbackSent(_ message: MIDIVoiceMessage, at now: Date) {
        recentFeedback[message.controlID] = (message.dataValue, now)
        if let control = hardwareMap.control(for: message.controlID), control.isContinuous,
           let assignment = configuration.assignment(for: control), assignment.encoderMode == .absolute,
           case let .parameter(id) = assignment.target, let definition = configuration.parameter(id),
           definition.kind == .toggle || definition.step != nil
        {
            if var accumulated = absoluteInputs[control], accumulated.maximum == message.maximumDataValue {
                accumulated.reference = Double(message.dataValue); absoluteInputs[control] = accumulated
            } else {
                absoluteInputs[control] = AbsoluteInput(
                    logical: Double(message.dataValue),
                    reference: Double(message.dataValue),
                    maximum: message.maximumDataValue
                )
            }
        }
    }

    // MARK: Queries

    public func value(of parameter: ParameterID) -> Double? {
        guard let definition = configuration.parameter(parameter) else {
            return nil
        }
        return definition.clamp(parameterValues[parameter] ?? definition.defaultValue)
    }

    public func state(of control: BCRControlID) -> SurfaceControlState {
        controls[control] ?? SurfaceControlState()
    }

    // MARK: Device input

    public func isFeedbackEcho(_ message: MIDIVoiceMessage, at time: Date) -> Bool {
        let mode = hardwareMap.control(for: message.controlID).flatMap { configuration.assignment(for: $0) }?
            .encoderMode ?? .absolute
        guard mode == .absolute, let feedback = recentFeedback[message.controlID] else { return false }
        return feedback.value == message.dataValue && time.timeIntervalSince(feedback.sentAt) < echoWindow
    }

    public mutating func handleInput(_ message: MIDIVoiceMessage, at now: Date = .now) -> [SurfaceEffect] {
        guard (try? message.validate()) != nil else { return [] }
        let midi = message.controlID
        let value = Self.controlValue(of: message)

        let mode = hardwareMap.control(for: midi).flatMap { configuration.assignment(for: $0) }?
            .encoderMode ?? .absolute
        let relative = mode != .absolute
        if !relative, isFeedbackEcho(message, at: now) { return [] }

        if let target = learnTarget {
            return learn(message, into: target, at: now)
        }

        guard let control = hardwareMap.control(for: midi) else {
            return [.unmappedInput(midi)]
        }
        record(control, value: value, direction: .input, rawValue: message.dataValue)
        if control.isContinuous, let assignment = configuration.assignment(for: control),
           case let .parameter(id) = assignment.target, let definition = configuration.parameter(id)
        {
            if assignment.encoderMode != .absolute {
                return applyRelative(
                    control,
                    delta: assignment.encoderMode.delta(value: message.dataValue, maximum: message.maximumDataValue),
                    at: now
                )
            }
            if definition.kind == .toggle || definition.step != nil {
                var accumulated = absoluteInputs[control] ?? AbsoluteInput(
                    logical: Double(message.dataValue),
                    reference: Double(message.dataValue),
                    maximum: message.maximumDataValue
                )
                if accumulated.maximum != message.maximumDataValue {
                    accumulated = AbsoluteInput(
                        logical: Double(message.dataValue),
                        reference: Double(message.dataValue),
                        maximum: message.maximumDataValue
                    )
                }
                accumulated.logical = min(
                    max(accumulated.logical + Double(message.dataValue) - accumulated.reference, 0),
                    Double(accumulated.maximum)
                )
                accumulated.reference = Double(message.dataValue); absoluteInputs[control] = accumulated
                let normalized = assignment.inverted ? 1 - accumulated
                    .logical / Double(accumulated.maximum) : accumulated.logical / Double(accumulated.maximum)
                clearIncrementRemainders(for: id)
                parameterValues[id] = definition
                    .clamp(definition.minimum + normalized * (definition.maximum - definition.minimum))
                return feedback(to: configuration.controls(targetingParameter: id), at: now)
            }
            if message.maximumDataValue == 16383 {
                let raw = assignment.inverted ? 16383 - message.dataValue : message.dataValue
                clearIncrementRemainders(for: id)
                parameterValues[id] = definition
                    .clamp(definition.minimum + Double(raw) / 16383 * (definition.maximum - definition.minimum))
                let bound = configuration.controls(targetingParameter: id)
                let targets = feedbackDataValue(for: control) == message.dataValue ? bound
                    .filter { $0 != control } : bound
                return feedback(to: targets, at: now)
            }
        }
        return apply(control, value: value, isPositive: message.isPositiveActivation, fromDevice: true, at: now)
    }

    // MARK: Software input (virtual panel in hardware mode, inspector, parameter list)

    /// Turns a control from the software side, as if the user had moved it.
    public mutating func adjust(_ control: BCRControlID, by delta: Int, at now: Date = .now) -> [SurfaceEffect] {
        guard control.isContinuous, delta != 0 else {
            return []
        }
        if configuration.assignment(for: control)?.encoderMode != nil,
           configuration.assignment(for: control)?.encoderMode != .absolute
        {
            return applyRelative(control, delta: delta, at: now)
        }
        if hardwareMap.midi(for: control)?.kind == .nrpn,
           let assignment = configuration.assignment(for: control), case let .parameter(id) = assignment.target,
           let definition = configuration.parameter(id)
        {
            let direction = assignment.inverted ? -1.0 : 1.0
            return incrementParameter(
                control,
                id: id,
                movement: direction * Double(delta) * (definition.maximum - definition.minimum) / 16383,
                at: now
            )
        }
        let current = Int(feedbackValue(for: control) ?? state(of: control).value)
        let next = UInt8(min(max(current + delta, 0), 127))
        guard Int(next) != current else {
            return []
        }
        record(control, value: next, direction: .output)
        let effects = apply(control, value: next, isPositive: next >= 64, fromDevice: false, at: now)
        if configuration.assignment(for: control) == nil {
            return effects + feedback(to: [control], at: now)
        }
        return effects
    }

    /// Presses (`isDown`) or releases a button from the software side.
    public mutating func press(_ control: BCRControlID, isDown: Bool, at now: Date = .now) -> [SurfaceEffect] {
        guard !control.isContinuous else {
            return []
        }
        let value: UInt8 = isDown ? 127 : 0
        record(control, value: value, direction: .output)
        return apply(control, value: value, isPositive: isDown, fromDevice: false, at: now)
    }

    public mutating func setParameter(_ id: ParameterID, to value: Double, at now: Date = .now) -> [SurfaceEffect] {
        guard let definition = configuration.parameter(id) else {
            return []
        }
        clearIncrementRemainders(for: id)
        for control in configuration.controls(targetingParameter: id) { absoluteInputs[control] = nil }
        parameterValues[id] = definition.clamp(value)
        return feedback(to: configuration.controls(targetingParameter: id), at: now)
    }

    public mutating func resetGroup(_ group: String, at now: Date = .now) -> [SurfaceEffect] {
        configuration.parameters
            .filter { $0.group == group }
            .flatMap { setParameter($0.id, to: $0.defaultValue, at: now) }
    }

    /// Records an agent slot's LED value and writes it to every control bound to that slot.
    public mutating func bindIndicator(_ indicator: IndicatorID, to target: ControlTarget) {
        pluginBindings.indicators[target] = indicator
    }

    public mutating func setIndicatorFeedback(_ id: IndicatorID, value: UInt8, at now: Date = .now) -> [SurfaceEffect] {
        indicatorFeedback[id] = min(value, 127)
        let controls = configuration.assignments.filter { pluginBindings.indicators[$0.target] == id }.map(\.control)
        return feedback(to: controls, at: now)
    }

    /// Writes the software state to every bound, assigned control (connect / device switch).
    public mutating func fullFeedback(at now: Date = .now) -> [SurfaceEffect] {
        feedback(to: configuration.assignments.map(\.control), at: now)
    }

    public mutating func setActualFeedback(_ values: [ParameterID: Double],
                                           at now: Date = .now) throws -> [SurfaceEffect]
    {
        for (id, value) in values {
            guard configuration.parameter(id) != nil,
                  value.isFinite else { throw MotionSafetyError(L10n.text("实际状态参数未知或数值无效")) }
        }
        var changed: [BCRControlID] = []
        for (id, value) in values where actualFeedbackValues[id] != value {
            actualFeedbackValues[id] = value
            if ledFeedbackSource == .actual {
                changed += configuration.controls(targetingParameter: id).filter {
                    $0.isContinuous && feedbackDataValue(for: $0) != state(of: $0).rawValue
                }
            }
        }
        return feedback(to: changed, at: now)
    }

    public mutating func setLEDFeedbackSource(_ source: LEDFeedbackSource, at now: Date = .now) -> [SurfaceEffect] {
        ledFeedbackSource = source
        return fullFeedback(at: now)
    }

    // MARK: Configuration

    public mutating func assign(_ assignment: ControlAssignment, at now: Date = .now) throws -> [SurfaceEffect] {
        try configuration.assign(assignment)
        incrementRemainders[assignment.control] = nil
        return feedback(to: [assignment.control], at: now)
    }

    public mutating func clearAssignment(for control: BCRControlID) {
        configuration.clearAssignment(for: control)
        incrementRemainders[control] = nil
    }

    public mutating func addParameter(_ definition: ParameterDefinition) throws {
        try configuration.addParameter(definition)
        parameterValues[definition.id] = definition.clamp(definition.defaultValue)
    }

    public mutating func updateParameter(_ definition: ParameterDefinition,
                                         at now: Date = .now) throws -> [SurfaceEffect]
    {
        try configuration.updateParameter(definition)
        return setParameter(definition.id, to: parameterValues[definition.id] ?? definition.defaultValue, at: now)
    }

    public mutating func removeParameter(_ id: ParameterID) {
        configuration.removeParameter(id)
        clearIncrementRemainders(for: id)
        parameterValues[id] = nil
        actualFeedbackValues[id] = nil
    }

    /// Resets parameters while preserving indicator feedback, bindings and device timing policy.
    /// Returned effects clear controls no longer assigned; follow with fullFeedback for the new snapshot.
    public mutating func replaceConfiguration(_ configuration: SurfaceConfiguration,
                                              at now: Date = .now) -> [SurfaceEffect]
    {
        let feedback = indicatorFeedback
        let pluginBindings = pluginBindings
        let echoWindow = echoWindow
        let triggerDebounce = triggerDebounce
        let recordFeedbackWhenGenerated = recordFeedbackWhenGenerated
        let removed = self.configuration.assignments.map(\.control).filter { configuration.assignment(for: $0) == nil }
        self = SurfaceEngine(hardwareMap: hardwareMap, configuration: configuration, pluginBindings: pluginBindings)
        indicatorFeedback = feedback
        self.echoWindow = echoWindow
        self.triggerDebounce = triggerDebounce
        self.recordFeedbackWhenGenerated = recordFeedbackWhenGenerated
        for control in removed { record(control, value: 0, direction: .output) }
        return self.feedback(to: removed, at: now)
    }

    public mutating func updatePrograms(_ candidate: SurfaceConfiguration,
                                        at now: Date = .now) throws -> [SurfaceEffect]
    {
        try candidate.validate()
        guard candidate.parameters == configuration.parameters
        else { throw MotionSafetyError(L10n.text("页面编辑不能修改参数定义")) }
        let old = configuration.assignments.map(\.control)
        configuration = candidate
        incrementRemainders.removeAll()
        absoluteInputs.removeAll()
        let removed = old.filter { configuration.assignment(for: $0) == nil }
        for control in removed { record(control, value: 0, direction: .output) }
        return [.programsChanged] + feedback(to: removed, at: now) + fullFeedback(at: now)
    }

    public mutating func selectPage(_ id: String?, at now: Date = .now) throws -> [SurfaceEffect] {
        let oldControls = configuration.assignments.map(\.control)
        try configuration.selectPage(id)
        incrementRemainders.removeAll()
        absoluteInputs.removeAll()
        recentFeedback.removeAll()
        absoluteInputs.removeAll()
        let removed = oldControls.filter { configuration.assignment(for: $0) == nil }
        for control in removed { record(control, value: 0, direction: .output) }
        return [.pageChanged] + feedback(to: removed, at: now) + fullFeedback(at: now)
    }

    public mutating func runMacro(_ id: String, at now: Date = .now) -> [SurfaceEffect] {
        guard let macro = configuration.macros.first(where: { $0.id == id }) else { return [] }
        var effects: [SurfaceEffect] = []
        for action in macro.actions {
            switch action {
            case let .set(parameter, value): effects += setParameter(parameter, to: value, at: now)
            case let .step(parameter, delta):
                if let current = value(of: parameter), (current + delta).isFinite {
                    effects += setParameter(parameter, to: current + delta, at: now)
                }
            case let .resetGroup(group): effects += resetGroup(group, at: now)
            }
        }
        return effects
    }

    // MARK: Hardware map / learning

    public mutating func replaceHardwareMap(_ map: HardwareMap) {
        hardwareMap = map
        incrementRemainders.removeAll()
        absoluteInputs.removeAll()
        learnTarget = nil
        recentFeedback.removeAll()
        absoluteInputs.removeAll()
    }

    public mutating func beginLearning(_ control: BCRControlID) {
        learnTarget = control
    }

    public mutating func stopLearning() {
        learnTarget = nil
    }

    public mutating func unbind(_ control: BCRControlID) {
        hardwareMap.unbind(control)
        incrementRemainders[control] = nil
    }

    public mutating func resetHardwareMap() {
        hardwareMap.reset()
        incrementRemainders.removeAll()
        absoluteInputs.removeAll()
        learnTarget = nil
    }

    private mutating func learn(_ message: MIDIVoiceMessage, into target: BCRControlID,
                                at now: Date) -> [SurfaceEffect]
    {
        let midi = message.controlID
        let value = Self.controlValue(of: message)

        // Messages from controls that are already learned (e.g. the encoder the user is still
        // turning after it was bound) only update the surface; they never rebind or trigger.
        if let existing = hardwareMap.control(for: midi), existing != target {
            record(existing, value: value, direction: .input)
            return []
        }
        // Buttons are learned on press, so the release of the same press cannot bind the next one.
        guard target.isContinuous || message.isPositiveActivation else {
            return []
        }

        do {
            try hardwareMap.bind(target, to: midi)
        } catch {
            return [.learnRejected(target, error)]
        }

        incrementRemainders[target] = nil
        record(target, value: value, direction: .input)
        learnTarget = BCRLayout.controls(in: target.section)
            .first { $0 > target && hardwareMap.midi(for: $0) == nil }
        return [.learned(target, midi)] + feedback(to: [target], at: now)
    }

    // MARK: Function application

    private mutating func apply(
        _ control: BCRControlID,
        value: UInt8,
        isPositive: Bool,
        fromDevice: Bool,
        at now: Date
    ) -> [SurfaceEffect] {
        guard let assignment = configuration.assignment(for: control) else {
            return []
        }

        if let action = pluginBindings.actions[assignment.target] {
            guard isPositive, acceptTrigger(control, at: now) else { return feedback(to: [control], at: now) }
            // Feedback precedes synchronous action callbacks, just as on the legacy path.
            return feedback(to: [control], at: now) + [.triggerAction(action)]
        }

        switch assignment.target {
        case let .switchPage(id):
            guard isPositive, acceptTrigger(control, at: now) else { return [] }
            return (try? selectPage(id, at: now)) ?? []
        case let .runMacro(id):
            guard isPositive, acceptTrigger(control, at: now) else { return [] }
            return runMacro(id, at: now)
        case let .parameter(id):
            guard let definition = configuration.parameter(id) else {
                return []
            }
            let bound = configuration.controls(targetingParameter: id)
            clearIncrementRemainders(for: id)
            if control.isContinuous {
                let input = assignment.inverted ? 127 - value : value
                parameterValues[id] = definition.value(fromMIDI: input)
                // The moved encoder already shows its position; only mirror it elsewhere.
                let expected = feedbackValue(for: control)
                // A snapped value can differ from the device's local ring. Correct the
                // origin only in that case; unchanged absolute inputs still mirror others.
                let targets = fromDevice && expected == value ? bound.filter { $0 != control } : bound
                return feedback(to: targets, at: now)
            }

            switch assignment.buttonBehavior {
            case .momentary:
                let isOn = isPositive != assignment.inverted
                parameterValues[id] = isOn ? definition.maximum : definition.minimum
            case .toggle:
                if isPositive, acceptTrigger(control, at: now) {
                    let current = self.value(of: id) ?? definition.defaultValue
                    parameterValues[id] = current >= definition.midpoint ? definition.minimum : definition.maximum
                }
            }
            return feedback(to: bound, at: now)

        case let .stepParameter(id, step, wraps):
            guard isPositive, acceptTrigger(control, at: now) else { return feedback(to: [control], at: now) }
            guard let definition = configuration.parameter(id), let current = self.value(of: id) else { return [] }
            return setParameter(
                id,
                to: steppedValue(current, definition: definition, step: step, wraps: wraps),
                at: now
            )

        case let .setParameter(id, value):
            guard isPositive, acceptTrigger(control, at: now) else { return feedback(to: [control], at: now) }
            return setParameter(id, to: value, at: now)

        case let .cycleParameter(id, values):
            guard isPositive, acceptTrigger(control, at: now) else { return feedback(to: [control], at: now) }
            guard let definition = configuration.parameter(id), let current = self.value(of: id),
                  !values.isEmpty else { return [] }
            let previous = values.firstIndex { approximatelyEqual(definition.clamp($0), current) }
            let next = previous.map { ($0 + 1) % values.count } ?? 0
            return setParameter(id, to: values[next], at: now)

        case let .agentPrimaryAction(slot):
            // Legacy-only fallback for callers that did not inject host bindings (D8).
            var effects: [SurfaceEffect] = []
            if isPositive, acceptTrigger(control, at: now) {
                effects.append(.triggerAgent(slot))
            }
            // Trigger callbacks may synchronously publish new Agent feedback. Send the
            // current LED snapshot first so it cannot overwrite that newer state.
            return feedback(to: [control], at: now) + effects

        case let .resetGroup(group):
            guard isPositive, acceptTrigger(control, at: now) else {
                return []
            }
            return resetGroup(group, at: now)
        }
    }

    private mutating func applyRelative(_ control: BCRControlID, delta: Int, at now: Date) -> [SurfaceEffect] {
        guard let assignment = configuration.assignment(for: control),
              case let .parameter(id) = assignment.target else { return [] }
        let movement = Double(delta) * assignment.encoderStep * (assignment.inverted ? -1 : 1)
        return incrementParameter(control, id: id, movement: movement, at: now)
    }

    private mutating func incrementParameter(_ control: BCRControlID, id: ParameterID, movement: Double,
                                             at now: Date) -> [SurfaceEffect]
    {
        guard let definition = configuration.parameter(id), let current = value(of: id) else { return [] }
        let pending = incrementRemainders[control]
        let base = pending?.parameter == id && pending?.anchor == current ? pending!.value : current
        let requested = base + movement
        // Retain fractions before snapping; clip at endpoints so no hidden wind-up accumulates.
        let bounded = requested.isFinite ? min(max(requested, definition.minimum), definition.maximum)
            : (movement > 0 ? definition.maximum : definition.minimum)
        let snapped = definition.clamp(bounded)
        if snapped != current { clearIncrementRemainders(for: id) }
        incrementRemainders[control] = .init(parameter: id, anchor: snapped, value: bounded)
        parameterValues[id] = snapped
        return feedback(to: configuration.controls(targetingParameter: id), at: now)
    }

    private mutating func clearIncrementRemainders(for id: ParameterID) {
        incrementRemainders = incrementRemainders.filter { $0.value.parameter != id }
    }

    private func steppedValue(_ current: Double, definition: ParameterDefinition, step: Double, wraps: Bool) -> Double {
        if step > 0, step > definition.maximum - current { return wraps ? definition.minimum : definition.maximum }
        if step < 0, -step > current - definition.minimum { return wraps ? definition.maximum : definition.minimum }
        return definition.clamp(current + step)
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs == rhs || abs(lhs - rhs) <= max(lhs.ulp, rhs.ulp) * 4
    }

    private mutating func acceptTrigger(_ control: BCRControlID, at now: Date) -> Bool {
        defer { lastTrigger[control] = now }
        guard let previous = lastTrigger[control] else {
            return true
        }
        return now.timeIntervalSince(previous) >= triggerDebounce
    }

    // MARK: Feedback

    private func feedbackValue(for control: BCRControlID) -> UInt8? {
        guard let assignment = configuration.assignment(for: control) else {
            return controls[control]?.value
        }
        if let indicator = pluginBindings.indicators[assignment.target] { return indicatorFeedback[indicator] ?? 0 }
        switch assignment.target {
        case let .switchPage(id): return (configuration.activePageID ?? SurfaceConfiguration.basePageID) == id ? 127 : 0
        case .runMacro: return 0
        case let .parameter(id):
            guard let definition = configuration.parameter(id) else { return nil }
            let useActual = control.isContinuous && definition.kind == .continuous && ledFeedbackSource == .actual
            guard let value = useActual ? actualFeedbackValues[id] : value(of: id) else { return nil }
            let midi = definition.midiValue(for: value, snap: !useActual)
            return assignment.inverted ? 127 - midi : midi
        case let .stepParameter(id, step, wraps):
            guard let definition = configuration.parameter(id), let current = value(of: id) else { return nil }
            return approximatelyEqual(
                steppedValue(current, definition: definition, step: step, wraps: wraps),
                current
            ) ?
                0 : 127
        case let .setParameter(id, preset):
            guard let definition = configuration.parameter(id), let current = value(of: id) else { return nil }
            return approximatelyEqual(definition.clamp(preset), current) ? 127 : 0
        case let .cycleParameter(id, values):
            guard let definition = configuration.parameter(id), let current = value(of: id) else { return nil }
            return values.contains { approximatelyEqual(definition.clamp($0), current) } ? 127 : 0
        case .agentPrimaryAction:
            return 0 // Legacy unbound indicator defaults to off; namespaces belong to the adapter.
        case .resetGroup:
            return nil
        }
    }

    private func feedbackDataValue(for control: BCRControlID) -> UInt16? {
        guard let midi = hardwareMap.midi(for: control), midi.kind == .nrpn else {
            return feedbackValue(for: control).map(UInt16.init)
        }
        if let assignment = configuration.assignment(for: control), case let .parameter(id) = assignment.target,
           let definition = configuration.parameter(id)
        {
            let useActual = control.isContinuous && definition.kind == .continuous && ledFeedbackSource == .actual
            guard let value = useActual ? actualFeedbackValues[id] : value(of: id) else { return nil }
            let bounded = min(max(useActual ? value : definition.clamp(value), definition.minimum), definition.maximum)
            let raw = UInt16(((bounded - definition.minimum) / (definition.maximum - definition.minimum) * 16383)
                .rounded())
            return assignment.inverted ? 16383 - raw : raw
        }
        return feedbackValue(for: control).map { UInt16((Double($0) * 16383 / 127).rounded()) }
    }

    private mutating func feedback(to targets: [BCRControlID], at now: Date) -> [SurfaceEffect] {
        targets.compactMap { control in
            guard let value = feedbackValue(for: control) else {
                return nil
            }
            let raw = feedbackDataValue(for: control) ?? UInt16(value)
            let presentation = hardwareMap.midi(for: control)?
                .kind == .nrpn ? UInt8((Double(raw) * 127 / 16383).rounded()) : value
            record(control, value: presentation, direction: .output, rawValue: raw)
            guard let midi = hardwareMap.midi(for: control) else {
                return nil
            }
            if recordFeedbackWhenGenerated { recentFeedback[midi] = (raw, now) }
            return .send(midi.kind == .nrpn ? MIDI1UMPCodec.feedback14(control: midi, value: raw) : MIDI1UMPCodec
                .feedback(
                    control: midi,
                    value: value
                ))
        }
    }

    private mutating func record(
        _ control: BCRControlID,
        value: UInt8,
        direction: MIDIObservationDirection,
        rawValue: UInt16? = nil
    ) {
        var state = controls[control] ?? SurfaceControlState()
        state.value = value
        state.rawValue = rawValue ?? UInt16(value)
        switch direction {
        case .input: state.lastInput = value
        case .output: state.lastOutput = value
        }
        state.lastDirection = direction
        state.eventCount += 1
        controls[control] = state
    }

    private static func controlValue(of message: MIDIVoiceMessage) -> UInt8 {
        if case .noteOff = message {
            return 0
        }
        return message.value
    }
}
