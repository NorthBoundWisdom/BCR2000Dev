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

struct BCLPresetWriteFailure: LocalizedMessageError {
    let line: Int
    let command: String
    let cause: MIDIStartupError

    init(index: Int, frame: [UInt8], cause: MIDIStartupError) {
        line = index + 1
        let payload = String(decoding: frame.dropFirst(9).dropLast(), as: UTF8.self)
        let token = payload.split(whereSeparator: \.isWhitespace).first ?? ""
        command = (2 ... 24).contains(token.count) && (token.first == "." || token.first == "$") &&
            token.dropFirst().utf8.allSatisfy { (97 ... 122).contains($0) } ? String(token) : "BCL"
        self.cause = cause
    }

    var localizedMessage: LocalizedMessage {
        switch cause {
        case .noReply:
            "BCL 第 \(line) 行（\(command)）未收到应答，已确认 \(line - 1) 行"
        case let .rejected(code):
            "设备拒绝 BCL 第 \(line) 行（\(command)），错误 \(code)（\(Self.reason(code))），已确认 \(line - 1) 行"
        case .invalidProgram:
            cause.localizedMessage
        }
    }

    private static func reason(_ code: Int) -> LocalizedMessage {
        switch code {
        case 1: "未知命令"
        case 2: "缺少命令"
        case 3: "缺少 MIDI 数据参数"
        case 4: "设备型号无效"
        case 5: "修订版本无效"
        case 6: "缺少修订版本声明"
        case 8: "缺少区块声明"
        case 9: "控件编号超出范围"
        case 10: "数字参数无效"
        case 11: "参数值超出范围"
        case 12: "文本参数无效"
        case 13: "当前区块不支持此设定"
        case 14: "参数个数无效"
        case 15: "MIDI 输出数据超限"
        case 18: "预设过于复杂"
        case 22: "消息序号无效"
        default: "设备未提供详细说明"
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
