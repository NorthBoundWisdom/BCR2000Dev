import BCRFoundation
import Foundation

/// Read-only identity discovery. Newly observed buttons cannot execute assigned actions.
public enum BCRPresetButtonLearning {
    public struct Plan: Sendable {
        public let hardwareMap: HardwareMap
        public let unconfigured: [BCRControlID]
        public let unsupported: [BCRControlID]
    }

    public static func prepare(dump: Data, existingMap: HardwareMap) throws -> Plan {
        let lines = try BCRPresetEncoderLearning.decodeLines(dump)
        guard lines.first == "$rev R1", lines.last == "$end",
              lines.filter({ $0 == "$preset" }).count == 1,
              lines.filter({ $0.hasPrefix(".egroups ") }) == [".egroups 4"] else { throw HardwareSnapshotError.invalid }
        var blocks: [Int: [String]] = [:]
        var button: Int?
        for line in lines {
            if line.hasPrefix("$") {
                button = nil
                if line.hasPrefix("$button ") {
                    guard let number = Int(line.dropFirst(8)), (1 ... 64).contains(number), blocks[number] == nil else {
                        throw HardwareSnapshotError.invalid
                    }
                    blocks[number] = []; button = number
                }
            } else if let button { blocks[button, default: []].append(line) }
        }
        var map = try existingMap.migrated()
        var missing: [BCRControlID] = [], unsupported: [BCRControlID] = []
        for number in 1 ... 52 {
            let control: BCRControlID = number <= 32
                ? .pushEncoderButton(group: (number - 1) / 8 + 1, (number - 1) % 8 + 1)
                : (number <= 48 ? .button(row: (number - 33) / 8 + 1, (number - 33) % 8 + 1) : .userButton(number - 48))
            guard let block = blocks[number], !block.isEmpty else { missing.append(control); continue }
            let definitions = block.filter { $0.hasPrefix(".easypar ") }
            let words = definitions.first?.split(separator: " ").map(String.init) ?? []
            guard definitions.count == 1, !block.contains(where: { $0.hasPrefix(".tx ") }),
                  words.count >= 7, ["CC", "NOTE"].contains(words[1]),
                  let channel = UInt8(words[2]), (1 ... 16).contains(channel),
                  let id = UInt8(words[3]), id < 128,
                  ["toggleon", "toggleoff", "increment"].contains(words[6])
            else {
                unsupported.append(control); continue
            }
            let midi = MIDIControlID(kind: words[1] == "CC" ? .controlChange : .note, channel: channel - 1, number: id)
            if let other = map.control(for: midi), other != control {
                unsupported.append(control); continue
            }
            if let previous = map.midi(for: control) {
                guard previous == midi else { throw HardwareSnapshotError.invalid }
            } else { try map.bind(control, to: midi, visualizationOnly: true) }
        }
        return Plan(hardwareMap: map, unconfigured: missing, unsupported: unsupported)
    }
}
