import Foundation

/// What the software believes one physical control currently shows.
public struct SurfaceControlState: Equatable, Sendable {
    public var value: UInt8 = 0
    public var lastInput: UInt8?
    public var lastOutput: UInt8?
    public var lastDirection: MIDIObservationDirection?
    public var eventCount = 0

    public init() {}
}

public enum MIDIObservationDirection: String, Equatable, Sendable {
    case input
    case output
}

public enum SurfaceEffect: Equatable, Sendable {
    /// Feedback to write to the device (LED ring / button LED).
    case send(MIDIVoiceMessage)
    case triggerAgent(AgentSlotID)
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
    public private(set) var agentFeedback: [AgentSlotID: UInt8] = [:]

    public var echoWindow: TimeInterval = 0.18
    public var triggerDebounce: TimeInterval = 0.25

    private var recentFeedback: [MIDIControlID: (value: UInt8, sentAt: Date)] = [:]
    private var lastTrigger: [BCRControlID: Date] = [:]

    public init(hardwareMap: HardwareMap, configuration: SurfaceConfiguration) {
        self.hardwareMap = hardwareMap
        self.configuration = configuration
        parameterValues = Dictionary(
            uniqueKeysWithValues: configuration.parameters.map { ($0.id, $0.defaultValue) }
        )
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

    public mutating func handleInput(_ message: MIDIVoiceMessage, at now: Date = .now) -> [SurfaceEffect] {
        let midi = message.controlID
        let value = Self.controlValue(of: message)

        if let feedback = recentFeedback[midi], feedback.value == value,
           now.timeIntervalSince(feedback.sentAt) < echoWindow {
            return []
        }

        if let target = learnTarget {
            return learn(message, into: target, at: now)
        }

        guard let control = hardwareMap.control(for: midi) else {
            return [.unmappedInput(midi)]
        }
        record(control, value: value, direction: .input)
        return apply(control, value: value, isPositive: message.isPositiveActivation, fromDevice: true, at: now)
    }

    // MARK: Software input (virtual panel in hardware mode, inspector, parameter list)

    /// Turns a control from the software side, as if the user had moved it.
    public mutating func adjust(_ control: BCRControlID, by delta: Int, at now: Date = .now) -> [SurfaceEffect] {
        guard control.isContinuous, delta != 0 else {
            return []
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
        parameterValues[id] = definition.clamp(value)
        return feedback(to: configuration.controls(targeting: .parameter(id)), at: now)
    }

    public mutating func resetGroup(_ group: String, at now: Date = .now) -> [SurfaceEffect] {
        configuration.parameters
            .filter { $0.group == group }
            .flatMap { setParameter($0.id, to: $0.defaultValue, at: now) }
    }

    /// Records an agent slot's LED value and writes it to every control bound to that slot.
    public mutating func setAgentFeedback(_ slot: AgentSlotID, value: UInt8, at now: Date = .now) -> [SurfaceEffect] {
        agentFeedback[slot] = min(value, 127)
        return feedback(to: configuration.controls(targeting: .agentPrimaryAction(slot)), at: now)
    }

    /// Writes the software state to every bound, assigned control (connect / device switch).
    public mutating func fullFeedback(at now: Date = .now) -> [SurfaceEffect] {
        feedback(to: configuration.assignments.map(\.control), at: now)
    }

    // MARK: Configuration

    public mutating func assign(_ assignment: ControlAssignment, at now: Date = .now) throws -> [SurfaceEffect] {
        try configuration.assign(assignment)
        return feedback(to: [assignment.control], at: now)
    }

    public mutating func clearAssignment(for control: BCRControlID) {
        configuration.clearAssignment(for: control)
    }

    public mutating func addParameter(_ definition: ParameterDefinition) throws {
        try configuration.addParameter(definition)
        parameterValues[definition.id] = definition.clamp(definition.defaultValue)
    }

    public mutating func updateParameter(_ definition: ParameterDefinition, at now: Date = .now) throws -> [SurfaceEffect] {
        try configuration.updateParameter(definition)
        return setParameter(definition.id, to: parameterValues[definition.id] ?? definition.defaultValue, at: now)
    }

    public mutating func removeParameter(_ id: ParameterID) {
        configuration.removeParameter(id)
        parameterValues[id] = nil
    }

    /// Configuration replacement resets parameters, while Agent state belongs to the session.
    /// Preserve its LED snapshot so the next full feedback can restore it in a single pass.
    public mutating func replaceConfiguration(_ configuration: SurfaceConfiguration) {
        let feedback = agentFeedback
        self = SurfaceEngine(hardwareMap: hardwareMap, configuration: configuration)
        agentFeedback = feedback
    }

    // MARK: Hardware map / learning

    public mutating func replaceHardwareMap(_ map: HardwareMap) {
        hardwareMap = map
        learnTarget = nil
        recentFeedback.removeAll()
    }

    public mutating func beginLearning(_ control: BCRControlID) {
        learnTarget = control
    }

    public mutating func stopLearning() {
        learnTarget = nil
    }

    public mutating func unbind(_ control: BCRControlID) {
        hardwareMap.unbind(control)
    }

    public mutating func resetHardwareMap() {
        hardwareMap.reset()
        learnTarget = nil
    }

    private mutating func learn(_ message: MIDIVoiceMessage, into target: BCRControlID, at now: Date) -> [SurfaceEffect] {
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

        switch assignment.target {
        case let .parameter(id):
            guard let definition = configuration.parameter(id) else {
                return []
            }
            let bound = configuration.controls(targeting: assignment.target)
            if control.isContinuous {
                let input = assignment.inverted ? 127 - value : value
                parameterValues[id] = definition.value(fromMIDI: input)
                // The moved encoder already shows its position; only mirror it elsewhere.
                let others = fromDevice ? bound.filter { $0 != control } : bound
                return feedback(to: others, at: now)
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

        case let .agentPrimaryAction(slot):
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
        switch assignment.target {
        case let .parameter(id):
            guard let definition = configuration.parameter(id), let value = value(of: id) else {
                return nil
            }
            let midi = definition.midiValue(for: value)
            return assignment.inverted ? 127 - midi : midi
        case let .agentPrimaryAction(slot):
            return agentFeedback[slot] ?? 0
        case .resetGroup:
            return nil
        }
    }

    private mutating func feedback(to targets: [BCRControlID], at now: Date) -> [SurfaceEffect] {
        targets.compactMap { control in
            guard let value = feedbackValue(for: control) else {
                return nil
            }
            record(control, value: value, direction: .output)
            guard let midi = hardwareMap.midi(for: control) else {
                return nil
            }
            recentFeedback[midi] = (value, now)
            return .send(MIDI1UMPCodec.feedback(control: midi, value: value))
        }
    }

    private mutating func record(_ control: BCRControlID, value: UInt8, direction: MIDIObservationDirection) {
        var state = controls[control] ?? SurfaceControlState()
        state.value = value
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
