import Foundation

public enum MIDIControlKind: String, Codable, Sendable {
    case controlChange
    case note
    case nrpn
}

public struct MIDIControlID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let kind: MIDIControlKind
    /// MIDI channels use the protocol-native zero-based range 0...15.
    public let channel: UInt8
    public let number: UInt16

    public init<T: BinaryInteger>(kind: MIDIControlKind, channel: UInt8, number: T) {
        precondition(channel < 16, "MIDI channel must be in 0...15")
        precondition(number >= 0 && number <= (kind == .nrpn ? 16383 : 127), "MIDI identity out of range")
        self.kind = kind
        self.channel = channel
        self.number = UInt16(number)
    }

    private enum CodingKeys: String, CodingKey { case kind, channel, number }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(MIDIControlKind.self, forKey: .kind)
        let channel = try container.decode(Int.self, forKey: .channel)
        let number = try container.decode(Int.self, forKey: .number)
        guard (0 ... 15).contains(channel), (0 ... (kind == .nrpn ? 16383 : 127)).contains(number) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "Invalid MIDI control channel/number"
            ))
        }
        self.init(kind: kind, channel: UInt8(channel), number: UInt16(number))
    }

    public var description: String {
        let prefix = kind == .controlChange ? "CC" : (kind == .nrpn ? "NRPN" : "Note")
        return "\(prefix) \(number) · Ch \(channel + 1)"
    }
}

public enum MIDIVoiceMessage: Equatable, Sendable {
    case nrpn(channel: UInt8, number: UInt16, value: UInt16)
    case controlChange(channel: UInt8, number: UInt8, value: UInt8)
    case noteOn(channel: UInt8, number: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, number: UInt8, velocity: UInt8)

    public var controlID: MIDIControlID {
        switch self {
        case let .nrpn(channel, number, _):
            MIDIControlID(kind: .nrpn, channel: channel, number: number)
        case let .controlChange(channel, number, _):
            MIDIControlID(kind: .controlChange, channel: channel, number: number)
        case let .noteOn(channel, number, _), let .noteOff(channel, number, _):
            MIDIControlID(kind: .note, channel: channel, number: number)
        }
    }

    public var value: UInt8 {
        switch self {
        case let .nrpn(_, _, value):
            UInt8((Double(value) * 127 / 16383).rounded())
        case let .controlChange(_, _, value):
            value
        case let .noteOn(_, _, velocity), let .noteOff(_, _, velocity):
            velocity
        }
    }

    /// Full protocol value; presentation remains seven-bit while NRPN transitions retain all bits.
    public var dataValue: UInt16 {
        if case let .nrpn(_, _, value) = self { return value }
        return UInt16(value)
    }

    public var maximumDataValue: UInt16 { if case .nrpn = self { return 16383 }; return 127 }

    public func validate() throws {
        switch self {
        case let .nrpn(channel, number, value):
            guard channel < 16, number < 16384, value < 16384 else { throw MIDIEncodingError.invalidMessage }
        case let .controlChange(channel, number, value),
             let .noteOn(channel, number, value), let .noteOff(channel, number, value):
            guard channel < 16, number < 128, value < 128 else { throw MIDIEncodingError.invalidMessage }
        }
    }

    /// Quick Learn intentionally accepts buttons configured as momentary controls.
    public var isPositiveActivation: Bool {
        switch self {
        case let .nrpn(_, _, value):
            value >= 8192
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
        case let .nrpn(channel, number, value):
            "NRPN ch\(channel + 1) #\(number) = \(value)"
        case let .controlChange(channel, number, value):
            "CC ch\(channel + 1) #\(number) = \(value)"
        case let .noteOn(channel, number, velocity):
            "Note On ch\(channel + 1) #\(number) = \(velocity)"
        case let .noteOff(channel, number, velocity):
            "Note Off ch\(channel + 1) #\(number) = \(velocity)"
        }
    }

    public var midi1Bytes: [UInt8] {
        switch self {
        case let .nrpn(channel, number, value):
            [0xB0 | channel, 99, UInt8((number >> 7) & 127),
             0xB0 | channel, 98, UInt8(number & 127),
             0xB0 | channel, 6, UInt8((value >> 7) & 127),
             0xB0 | channel, 38, UInt8(value & 127)]
        case let .controlChange(channel, number, value):
            [0xB0 | channel, number, value]
        case let .noteOn(channel, number, velocity):
            [0x90 | channel, number, velocity]
        case let .noteOff(channel, number, velocity):
            [0x80 | channel, number, velocity]
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

    public static func encode(_ message: MIDIVoiceMessage, group: UInt8 = 0) throws -> UInt32 {
        try message.validate()
        guard group < 16 else { throw MIDIEncodingError.invalidMessage }

        let status: UInt8
        let channel: UInt8
        let data1: UInt8
        let data2: UInt8

        switch message {
        case .nrpn: throw MIDIEncodingError.requiresMultipleWords
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

    public static func encodeWords(_ message: MIDIVoiceMessage, group: UInt8 = 0) throws -> [UInt32] {
        try message.validate()
        if case let .nrpn(channel, number, value) = message {
            return try [(UInt8(99), UInt8(number >> 7)), (98, UInt8(number & 127)),
                        (6, UInt8(value >> 7)), (38, UInt8(value & 127))].map {
                try encode(.controlChange(channel: channel, number: $0.0, value: $0.1), group: group)
            }
        }
        return [try encode(message, group: group)]
    }

    public static func feedback14(control: MIDIControlID, value: UInt16) -> MIDIVoiceMessage {
        if control.kind == .nrpn {
            return .nrpn(channel: control.channel, number: control.number, value: min(value, 16383))
        }
        return feedback(control: control, value: UInt8((Double(min(value, 16383)) * 127 / 16383).rounded()))
    }

    public static func feedback(control: MIDIControlID, value: UInt8) -> MIDIVoiceMessage {
        switch control.kind {
        case .nrpn:
            .nrpn(
                channel: control.channel,
                number: control.number,
                value: UInt16((Double(min(value, 127)) * 16383 / 127).rounded())
            )
        case .controlChange:
            .controlChange(
                channel: control.channel,
                number: UInt8(control.number),
                value: min(value, 127)
            )
        case .note:
            .noteOn(
                channel: control.channel,
                number: UInt8(control.number),
                velocity: min(value, 127)
            )
        }
    }
}

public enum MIDIEncodingError: Error, Equatable, Sendable {
    case invalidMessage, requiresMultipleWords
}

/// Strict 14-bit NRPN: complete selector then MSB/LSB data pair; never guesses missing bits.
/// State is independent per channel, survives callback boundaries, expires after 500 ms.
/// Non-selector CC/note interleaving is preserved by the caller; RPN selectors cancel NRPN.
public struct NRPNAssembler: Sendable {
    private struct Selection: Sendable {
        var msb: UInt8?
        var lsb: UInt8?
        var dataMSB: UInt8?
        var date: Date
    }

    private var channels: [UInt8: Selection] = [:]
    public init() {}
    public mutating func reset() { channels.removeAll() }
    public mutating func consume(_ message: MIDIVoiceMessage, at now: Date) -> MIDIVoiceMessage? {
        guard (try? message.validate()) != nil,
              case let .controlChange(channel, number, value) = message else { return nil }
        guard [6, 38, 98, 99, 100, 101, 121].contains(number) else { return nil }
        var state = channels[channel] ?? Selection(date: now)
        let elapsed = now.timeIntervalSince(state.date)
        if elapsed < 0 || elapsed >= 0.5 { state = Selection(date: now) }
        state.date = now
        var result: MIDIVoiceMessage?
        switch number {
        case 99: state = Selection(msb: value, date: now)
        case 98:
            state.lsb = value
            state.dataMSB = nil
        case 6:
            if state.msb != nil, state.lsb != nil { state.dataMSB = value }
        case 38:
            if let msb = state.msb, let lsb = state.lsb, let data = state.dataMSB {
                result = .nrpn(channel: channel, number: UInt16(msb) << 7 | UInt16(lsb),
                               value: UInt16(data) << 7 | UInt16(value))
            }
            state.dataMSB = nil
        case 100, 101, 121: state = Selection(date: now)
        default: break
        }
        channels[channel] = state
        return result
    }
}
