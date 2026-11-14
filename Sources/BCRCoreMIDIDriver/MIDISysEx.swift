import BCRFoundation
import Foundation

/// Failures of the BCL preset transfers (name/dump reads, acknowledged writes).
public enum MIDIStartupError: LocalizedMessageError {
    case invalidProgram, noReply, rejected(Int)
    public var localizedMessage: LocalizedMessage {
        switch self {
        case .invalidProgram: "设备不支持该预设操作或数据无效"
        case .noReply: "硬件未应答预设操作"
        case let .rejected(code): "硬件拒绝预设操作：\(code)"
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
