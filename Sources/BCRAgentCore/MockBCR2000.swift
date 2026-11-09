import Foundation

/// Behavioural model of a BCR2000 in USB mode U-1 running the mock's own preset.
///
/// Like the real device it keeps an internal 7-bit value per control, sends absolute CC values
/// when an encoder is turned, sends 127/0 for momentary buttons, and updates its LED rings and
/// button LEDs when it receives parameter feedback. It never echoes received feedback.
public struct MockBCR2000: Sendable {
    public let preset: HardwareMap
    public private(set) var values: [BCRControlID: UInt8] = [:]
    /// Which push-encoder group is shown on the top row. Group switching is local to the device
    /// and sends no MIDI, exactly like the real group buttons.
    public var activeGroup = 1 {
        didSet { activeGroup = min(max(activeGroup, BCRLayout.encoderGroups.lowerBound), BCRLayout.encoderGroups.upperBound) }
    }
    public private(set) var sentCount = 0
    public private(set) var receivedCount = 0

    public init(preset: HardwareMap = .mockPreset()) {
        self.preset = preset
    }

    public func value(of control: BCRControlID) -> UInt8 {
        values[control] ?? 0
    }

    /// Turns an encoder by `delta` detents. Returns nothing if the value is already at a limit.
    public mutating func turn(_ control: BCRControlID, by delta: Int) -> MIDIVoiceMessage? {
        guard control.isContinuous, let midi = preset.midi(for: control) else {
            return nil
        }
        let current = Int(value(of: control))
        let next = UInt8(min(max(current + delta, 0), 127))
        guard Int(next) != current else {
            return nil
        }
        values[control] = next
        sentCount += 1
        return MIDI1UMPCodec.feedback(control: midi, value: next)
    }

    public mutating func press(_ control: BCRControlID) -> MIDIVoiceMessage? {
        guard !control.isContinuous, let midi = preset.midi(for: control) else {
            return nil
        }
        values[control] = 127
        sentCount += 1
        return MIDI1UMPCodec.feedback(control: midi, value: 127)
    }

    public mutating func release(_ control: BCRControlID) -> MIDIVoiceMessage? {
        guard !control.isContinuous, let midi = preset.midi(for: control) else {
            return nil
        }
        values[control] = 0
        sentCount += 1
        switch midi.kind {
        case .controlChange:
            return .controlChange(channel: midi.channel, number: midi.number, value: 0)
        case .note:
            return .noteOff(channel: midi.channel, number: midi.number, velocity: 0)
        }
    }

    /// Applies incoming feedback. Returns the updated control, or nil if the preset has no
    /// control with that MIDI identity (the real device ignores such messages as well).
    @discardableResult
    public mutating func receive(_ message: MIDIVoiceMessage) -> BCRControlID? {
        receivedCount += 1
        guard let control = preset.control(for: message.controlID) else {
            return nil
        }
        if case .noteOff = message {
            values[control] = 0
        } else {
            values[control] = message.value
        }
        return control
    }
}
