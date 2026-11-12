import BCRFoundation
import Foundation

public enum MIDIStartupError: Error, LocalizedError {
    case invalidProgram, noReply, rejected(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidProgram: L10n.text("硬件启动配置无效")
        case .noReply: L10n.text("硬件未确认启动设置")
        case let .rejected(code): L10n.text("硬件拒绝启动设置：\(code)")
        }
    }
}

/// Explicit machine-local startup policy, captured from the user's managed preset.
/// The command sequence changes temporary preset settings only; it cannot clear controls or store flash.
public struct MIDIStartupProgram: Codable, Equatable, Sendable {
    public let version: Int
    public let preset: Int
    public let presetSettings: [String]

    private enum CodingKeys: String, CodingKey { case version, preset, presetSettings }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        preset = try c.decode(Int.self, forKey: .preset)
        presetSettings = try c.decode([String].self, forKey: .presetSettings)
        try validate()
    }

    public init(preset: Int, presetSettings: [String]) throws {
        version = 1; self.preset = preset; self.presetSettings = presetSettings
        try validate()
    }

    public func validate() throws {
        guard version == 1, (1 ... 32).contains(preset), presetSettings.count == 6,
              Set(presetSettings.map { $0.split(separator: " ").first.map(String.init) ?? "" }) ==
              Set([".name", ".snapshot", ".request", ".egroups", ".fkeys", ".lock"])
        else { throw MIDIStartupError.invalidProgram }
        for line in presetSettings {
            if line.hasPrefix(".name '") && line.hasSuffix("'") {
                let name = line.dropFirst(7).dropLast()
                guard name.count <= 24,
                      name.utf8.allSatisfy({ (32 ... 126).contains($0) && $0 != 39 })
                else { throw MIDIStartupError.invalidProgram }
            } else if ![
                ".snapshot off",
                ".request off",
                ".egroups 4",
                ".fkeys on",
                ".fkeys off",
                ".lock on",
                ".lock off"
            ].contains(line) {
                throw MIDIStartupError.invalidProgram
            }
        }
    }

    public var selectBytes: [UInt8] { [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x22, UInt8(preset - 1), 0xF7] }

    func frames() throws -> [[UInt8]] {
        try validate()
        let lines = ["$rev R1", "$preset"] + presetSettings
            .flatMap { $0 == ".egroups 4" ? [".egroups 1", ".egroups 4"] : [$0] } + ["$end"]
        return lines.enumerated().map { index, line in
            [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x20, UInt8(index >> 7), UInt8(index & 127)] + Array(line.utf8) + [0xF7]
        }
    }
}

struct MIDISysEx7Chunk: Sendable {
    let group: UInt8
    let status: UInt8
    let data: [UInt8]
    init?(word0: UInt32, word1: UInt32) {
        let count = Int((word0 >> 16) & 15), status = UInt8((word0 >> 20) & 15)
        guard word0 >> 28 == 3, count <= 6, status <= 3 else { return nil }
        let bytes = [
            UInt8((word0 >> 8) & 255),
            UInt8(word0 & 255),
            UInt8(word1 >> 24),
            UInt8((word1 >> 16) & 255),
            UInt8((word1 >> 8) & 255),
            UInt8(word1 & 255)
        ]
        let payload = Array(bytes.prefix(count))
        guard payload.allSatisfy({ $0 < 128 }) else { return nil }
        group = UInt8((word0 >> 24) & 15); self.status = status; data = payload
    }
}

struct MIDISysEx7Assembler {
    private var partial: [UInt8: [UInt8]] = [:]
    mutating func consume(_ chunk: MIDISysEx7Chunk) -> [UInt8]? {
        switch chunk.status {
        case 0: partial[chunk.group] = nil; return [0xF0] + chunk.data + [0xF7]
        case 1: partial[chunk.group] = [0xF0] + chunk.data
        case 2, 3:
            guard var bytes = partial[chunk.group] else { return nil }
            bytes += chunk.data
            guard bytes.count <= 8192 else { partial[chunk.group] = nil; return nil }
            if chunk.status == 3 { partial[chunk.group] = nil; return bytes + [0xF7] }
            partial[chunk.group] = bytes
        default: break
        }
        return nil
    }
}
