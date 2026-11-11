import Foundation

/// Explicit bulk learning from a real device's current BCL dump, corroborated by its snapshot.
/// Supports ordinary absolute 0...127 CC encoders only; never infers a preset or button identity.
public enum BCRPresetEncoderLearning {
    public struct Plan: Sendable {
        public let hardwareMap: HardwareMap
        public let configuration: SurfaceConfiguration
    }

    public enum Failure: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            if case let .invalid(reason) = self { return L10n.text("旋钮批量学习失败：\(reason)") }
            return nil
        }
    }

    public static func prepare(
        dump: Data, snapshot: [MIDIControlID: UInt8],
        existingMap: HardwareMap, configuration: SurfaceConfiguration
    ) throws -> Plan {
        try existingMap.validate()
        try configuration.validate()
        let lines = try decodeLines(dump)
        guard lines.first == "$rev R1", lines.last == "$end",
              lines.filter({ $0 == "$preset" }).count == 1,
              lines.filter({ $0.hasPrefix(".egroups ") }) == [".egroups 4"]
        else { throw Failure.invalid(L10n.text("需要完整的单个当前预设")) }
        var identities: [Int: MIDIControlID] = [:]
        var encoder: Int?
        var seenEncoders = Set<Int>()
        var inPreset = false
        for line in lines.dropFirst().dropLast() {
            let words = line.split(separator: " ").map(String.init)
            guard let statement = words.first else { throw Failure.invalid(L10n.text("空语句")) }
            if statement == "$preset" { inPreset = true; encoder = nil; continue }
            if statement == "$encoder" {
                guard inPreset, words.count == 2, let number = Int(words[1]), (1 ... 56).contains(number),
                      seenEncoders.insert(number).inserted
                else { throw Failure.invalid(L10n.text("编码器编号无效或重复")) }
                encoder = number
                continue
            }
            if statement == "$button" { encoder = nil; continue }
            guard !statement.hasPrefix("$") else { throw Failure.invalid(L10n.text("不支持的预设区块")) }
            guard let encoder else { continue }
            switch statement {
            case ".easypar":
                guard identities[encoder] == nil, words.count == 7, words[1] == "CC",
                      let channel = UInt8(words[2]), (1 ... 16).contains(channel),
                      let number = UInt8(words[3]), number < 128,
                      words[4...] == ["0", "127", "absolute"]
                else { throw Failure.invalid(L10n.text("只支持 0…127 的普通绝对 CC 旋钮")) }
                identities[encoder] = MIDIControlID(kind: .controlChange, channel: channel - 1, number: number)
            case ".showvalue":
                guard words.count == 2, ["on", "off"].contains(words[1]) else {
                    throw Failure.invalid(L10n.text("无效的显示设置"))
                }
            case ".mode":
                guard words.count == 2,
                      ["off", "1dot", "1dot/off", "12dot", "12dot/off", "bar", "bar/off",
                       "spread", "pan", "qual", "cut", "damp"].contains(words[1])
                else { throw Failure.invalid(L10n.text("未知灯环模式")) }
            case ".resolution":
                guard words.count == 5, words.dropFirst().allSatisfy({ UInt16($0).map { $0 > 0 } ?? false })
                else { throw Failure.invalid(L10n.text("无效的旋钮分辨率")) }
            case ".default":
                guard words.count == 2, let value = UInt8(words[1]), value < 128 else {
                    throw Failure.invalid(L10n.text("无效的默认值"))
                }
            default: throw Failure.invalid(L10n.text("不支持的编码器语句 \(statement)"))
            }
        }
        guard identities.count == 56 else { throw Failure.invalid(L10n.text("预设未提供全部 56 个旋钮定义")) }
        var map = existingMap
        var result = configuration
        for number in 1 ... 56 {
            let control: BCRControlID = number <= 32
                ? .pushEncoder(group: (number - 1) / 8 + 1, (number - 1) % 8 + 1)
                : .encoder(row: (number - 33) / 8 + 1, (number - 33) % 8 + 1)
            guard let midi = identities[number], let value = snapshot[midi], value < 128 else {
                throw Failure.invalid(L10n.text("\(control.shortName) 缺少当前设备快照"))
            }
            if let previous = map.midi(for: control), previous != midi {
                throw Failure.invalid(L10n.text("\(control.shortName) 与已有学习身份不同，保留原映射"))
            }
            try map.bind(control, to: midi)
            if let assignment = result.assignment(for: control) {
                guard assignment.encoderMode == .absolute else {
                    throw Failure.invalid(L10n.text("\(control.shortName) 的已有功能不是绝对模式"))
                }
                continue
            }
            let id = result.makeParameterID(prefix: "surface")
            try result.addParameter(ParameterDefinition(
                id: id, name: control.shortName, group: control.section == .pushEncoder
                    ? L10n.text("顶部旋钮 · 组\(control.row)") : L10n.text("下方旋钮 · 第\(control.row)行"),
                minimum: 0, maximum: 127, defaultValue: Double(value)
            ))
            try result.assign(ControlAssignment(control: control, target: .parameter(id)))
        }
        return Plan(hardwareMap: map, configuration: result)
    }

    private static func decodeLines(_ data: Data) throws -> [String] {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw Failure.invalid(L10n.text("预设大小无效")) }
        let bytes = Array(data)
        var offset = 0
        var lines: [String] = []
        var device: UInt8?
        while offset < bytes.count {
            guard let end = bytes[offset...].firstIndex(of: 0xF7), end - offset >= 10 else {
                throw Failure.invalid(L10n.text("SysEx 帧不完整"))
            }
            let frame = Array(bytes[offset ... end])
            guard frame[0 ... 3] == [0xF0, 0, 0x20, 0x32], frame[4] < 16,
                  frame[5] == 0x15, frame[6] == 0x20,
                  frame[1 ..< frame.count - 1].allSatisfy({ $0 < 128 }),
                  Int(frame[7]) * 128 + Int(frame[8]) == lines.count,
                  device == nil || device == frame[4],
                  frame[9 ..< frame.count - 1].allSatisfy({ (32 ... 126).contains($0) }),
                  let text = String(bytes: frame[9 ..< frame.count - 1], encoding: .ascii)
            else { throw Failure.invalid(L10n.text("设备、行序号或 BCL 帧无效")) }
            device = frame[4]
            lines.append(text.trimmingCharacters(in: .whitespaces))
            offset = end + 1
        }
        return lines
    }
}
