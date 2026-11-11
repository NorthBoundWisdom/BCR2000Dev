import BCRFoundation
import Foundation

/// Behavioural model of a BCR2000 in USB mode U-1 running the mock's own preset.
///
/// Like the real device it keeps an internal 7-bit value per control, sends absolute CC values
/// when an encoder is turned, sends 127/0 for momentary buttons, and updates its LED rings and
/// button LEDs when it receives parameter feedback. It never echoes received feedback.
/// These device-behaviour assumptions (including group switching) are 待 R1 实机验证.
public struct MockBCR2000: Sendable {
    public private(set) var preset: HardwareMap
    public private(set) var rawValues: [BCRControlID: UInt16] = [:]
    public var encoderModes: [BCRControlID: EncoderMode] = [:]
    public private(set) var values: [BCRControlID: UInt8] = [:]
    /// Which push-encoder group is shown on the top row. Group switching is local to the device
    /// and sends no MIDI, exactly like the real group buttons.
    public var activeGroup = 1 {
        didSet { activeGroup = min(
            max(activeGroup, BCRLayout.encoderGroups.lowerBound),
            BCRLayout.encoderGroups.upperBound
        ) }
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
        let maximum: UInt16 = midi.kind == .nrpn ? 16383 : 127
        let mode = encoderModes[control] ?? .absolute
        if mode != .absolute {
            // BCR Relative 1: two's complement; Relative 2: binary offset (manual §4.3).
            // Encoded tick magnitude models acceleration; 待 R1 实机验证.
            let raw = mode.encoded(delta: delta, maximum: maximum)
            guard delta != 0 else { return nil }
            sentCount += 1
            // Relative sends do not replace the absolute LED position.
            return midi.kind == .nrpn
                ? .nrpn(channel: midi.channel, number: midi.number, value: raw)
                : .controlChange(channel: midi.channel, number: UInt8(midi.number), value: UInt8(raw))
        }
        if midi.kind == .nrpn {
            let current = Int(rawValues[control] ?? 0)
            let next = UInt16(min(max(current + min(max(delta, -16383), 16383), 0), 16383))
            guard Int(next) != current else { return nil }
            rawValues[control] = next
            values[control] = UInt8((Double(next) * 127 / 16383).rounded())
            sentCount += 1
            return .nrpn(channel: midi.channel, number: midi.number, value: next)
        }
        let current = Int(value(of: control))
        let next = UInt8(min(max(current + min(max(delta, -127), 127), 0), 127))
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
        case .nrpn:
            return .nrpn(channel: midi.channel, number: midi.number, value: 0)
        case .controlChange:
            return .controlChange(channel: midi.channel, number: UInt8(midi.number), value: 0)
        case .note:
            return .noteOff(channel: midi.channel, number: UInt8(midi.number), velocity: 0)
        }
    }

    /// Explicit Mock-only resolution experiment; never changes a physical device preset.
    public mutating func setNRPN(_ enabled: Bool, for control: BCRControlID) throws {
        guard control.isContinuous,
              let original = HardwareMap.mockPreset().midi(for: control)
        else { throw HardwareBindingError.invalidMap(L10n.text("只有 Mock 编码器可切换 NRPN")) }
        let identity = enabled ? MIDIControlID(kind: .nrpn, channel: 15, number: original.number) : original
        try preset.bind(control, to: identity)
    }

    /// Applies incoming feedback. Returns the updated control, or nil if the preset has no
    /// control with that MIDI identity (the real device ignores such messages as well).
    @discardableResult
    public mutating func receive(_ message: MIDIVoiceMessage) -> BCRControlID? {
        guard (try? message.validate()) != nil else { return nil }
        receivedCount += 1
        guard let control = preset.control(for: message.controlID) else {
            return nil
        }
        rawValues[control] = message.dataValue
        if case .noteOff = message {
            values[control] = 0
        } else {
            values[control] = message.value
        }
        return control
    }
}
