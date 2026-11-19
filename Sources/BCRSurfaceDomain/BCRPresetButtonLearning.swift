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
        var blocks: [Int: [(line: Int, text: String)]] = [:]
        var button: Int?
        for (offset, line) in lines.enumerated() {
            if line.hasPrefix("$") {
                button = nil
                if line.hasPrefix("$button ") {
                    guard let number = Int(line.dropFirst(8)), (1 ... 64).contains(number), blocks[number] == nil else {
                        throw HardwareSnapshotError.invalid
                    }
                    blocks[number] = []; button = number
                }
            } else if let button { blocks[button, default: []].append((offset + 1, line)) }
        }
        var map = try existingMap.migrated()
        var missing: [BCRControlID] = [], unsupported: [BCRControlID] = []
        for number in 1 ... 52 {
            let control: BCRControlID = number <= 32
                ? .pushEncoderButton(group: (number - 1) / 8 + 1, (number - 1) % 8 + 1)
                : (number <= 48 ? .button(row: (number - 33) / 8 + 1, (number - 33) % 8 + 1) : .userButton(number - 48))
            guard let block = blocks[number], !block.isEmpty else { missing.append(control); continue }
            let definitions = block.filter { $0.text.hasPrefix(".easypar ") }
            guard definitions.count == 1, let definition = definitions.first,
                  !block.contains(where: { $0.text == ".tx" || $0.text.hasPrefix(".tx ") }),
                  let binding = BCRPresetInspection.binding(
                      definition.text.split(whereSeparator: \.isWhitespace), line: definition.line, kind: .button
                  ),
                  binding.address.message == .cc || binding.address.message == .note
            else {
                unsupported.append(control); continue
            }
            let address = binding.address
            let midi = MIDIControlID(kind: address.message == .cc ? .controlChange : .note,
                                     channel: UInt8(address.channel - 1), number: UInt8(address.number))
            if let other = map.control(for: midi), other != control {
                unsupported.append(control); continue
            }
            if let previous = map.midi(for: control) {
                guard previous == midi else { throw HardwareSnapshotError.invalid }
            }
            let preview = map.midi(for: control) == nil || map.isVisualizationOnly(control)
            let sendsPressAndRelease = address.message == .note
                ? (binding.value2 ?? 0) > 0 : binding.value1 == 127 && binding.value2 == 0
            let pressMode: HardwarePressMode = binding.mode == "toggleoff" && sendsPressAndRelease ? .momentary : .pulse
            try map.bind(control, to: midi, visualizationOnly: preview, pressMode: pressMode)
        }
        return Plan(hardwareMap: map, unconfigured: missing, unsupported: unsupported)
    }
}
