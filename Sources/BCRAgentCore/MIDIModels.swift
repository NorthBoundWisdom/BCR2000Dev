import Foundation

public enum MIDIControlKind: String, Codable, Sendable {
    case controlChange
    case note
}

public struct MIDIControlID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let kind: MIDIControlKind
    /// MIDI channels use the protocol-native zero-based range 0...15.
    public let channel: UInt8
    public let number: UInt8

    public init(kind: MIDIControlKind, channel: UInt8, number: UInt8) {
        precondition(channel < 16, "MIDI channel must be in 0...15")
        precondition(number < 128, "MIDI data byte must be in 0...127")
        self.kind = kind
        self.channel = channel
        self.number = number
    }

    public var description: String {
        let prefix = kind == .controlChange ? "CC" : "Note"
        return "\(prefix) \(number) · Ch \(channel + 1)"
    }
}

public enum MIDIVoiceMessage: Equatable, Sendable {
    case controlChange(channel: UInt8, number: UInt8, value: UInt8)
    case noteOn(channel: UInt8, number: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, number: UInt8, velocity: UInt8)

    public var controlID: MIDIControlID {
        switch self {
        case let .controlChange(channel, number, _):
            MIDIControlID(kind: .controlChange, channel: channel, number: number)
        case let .noteOn(channel, number, _), let .noteOff(channel, number, _):
            MIDIControlID(kind: .note, channel: channel, number: number)
        }
    }

    public var value: UInt8 {
        switch self {
        case let .controlChange(_, _, value):
            value
        case let .noteOn(_, _, velocity), let .noteOff(_, _, velocity):
            velocity
        }
    }

    /// Quick Learn intentionally accepts buttons configured as momentary controls.
    public var isPositiveActivation: Bool {
        switch self {
        case let .controlChange(_, _, value):
            value >= 64
        case let .noteOn(_, _, velocity):
            velocity > 0
        case .noteOff:
            false
        }
    }

    public var diagnosticDescription: String {
        switch self {
        case let .controlChange(channel, number, value):
            "CC ch\(channel + 1) #\(number) = \(value)"
        case let .noteOn(channel, number, velocity):
            "Note On ch\(channel + 1) #\(number) = \(velocity)"
        case let .noteOff(channel, number, velocity):
            "Note Off ch\(channel + 1) #\(number) = \(velocity)"
        }
    }
}

/// Stateless MIDI 1.0 Universal MIDI Packet encoder/decoder.
public enum MIDI1UMPCodec {
    public static func wordCount(forFirstWord word: UInt32) -> Int {
        switch UInt8((word >> 28) & 0x0F) {
        case 0x00, 0x01, 0x02, 0x06, 0x07:
            1
        case 0x03, 0x04, 0x08, 0x09, 0x0A:
            2
        case 0x0B, 0x0C:
            3
        case 0x05, 0x0D, 0x0E, 0x0F:
            4
        default:
            1
        }
    }

    public static func decode(words: [UInt32]) -> [MIDIVoiceMessage] {
        var result: [MIDIVoiceMessage] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if let message = decode(word: word) {
                result.append(message)
            }
            index += min(wordCount(forFirstWord: word), words.count - index)
        }
        return result
    }

    public static func decode(word: UInt32) -> MIDIVoiceMessage? {
        let messageType = UInt8((word >> 28) & 0x0F)
        guard messageType == 0x02 else {
            return nil
        }

        let status = UInt8((word >> 20) & 0x0F)
        let channel = UInt8((word >> 16) & 0x0F)
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)

        switch status {
        case 0x08:
            return .noteOff(channel: channel, number: data1, velocity: data2)
        case 0x09:
            if data2 == 0 {
                return .noteOff(channel: channel, number: data1, velocity: 0)
            }
            return .noteOn(channel: channel, number: data1, velocity: data2)
        case 0x0B:
            return .controlChange(channel: channel, number: data1, value: data2)
        default:
            return nil
        }
    }

    public static func encode(_ message: MIDIVoiceMessage, group: UInt8 = 0) -> UInt32 {
        precondition(group < 16, "UMP group must be in 0...15")

        let status: UInt8
        let channel: UInt8
        let data1: UInt8
        let data2: UInt8

        switch message {
        case let .controlChange(messageChannel, number, value):
            status = 0x0B
            channel = messageChannel
            data1 = number
            data2 = value
        case let .noteOn(messageChannel, number, velocity):
            status = 0x09
            channel = messageChannel
            data1 = number
            data2 = velocity
        case let .noteOff(messageChannel, number, velocity):
            status = 0x08
            channel = messageChannel
            data1 = number
            data2 = velocity
        }

        return UInt32(0x02) << 28
            | UInt32(group) << 24
            | UInt32(status) << 20
            | UInt32(channel & 0x0F) << 16
            | UInt32(data1 & 0x7F) << 8
            | UInt32(data2 & 0x7F)
    }

    public static func feedback(control: MIDIControlID, value: UInt8) -> MIDIVoiceMessage {
        switch control.kind {
        case .controlChange:
            .controlChange(
                channel: control.channel,
                number: control.number,
                value: min(value, 127)
            )
        case .note:
            .noteOn(
                channel: control.channel,
                number: control.number,
                velocity: min(value, 127)
            )
        }
    }
}
