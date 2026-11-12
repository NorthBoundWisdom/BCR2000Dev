import BCRSurfaceDomain
import Foundation

/// Synthetic preset data shared by test targets; never a learned physical-device profile.
public enum BCLFixtures {
    public static func dump(_ lines: [String], device: UInt8 = 0) -> Data {
        Data(lines.enumerated().flatMap { index, line in
            [0xF0, 0, 0x20, 0x32, device, 0x15, 0x20, UInt8(index >> 7), UInt8(index & 127)]
                + Array(line.utf8) + [0xF7]
        })
    }

    public static func encoderSections(properties: (Int) -> [String] = {
        [".easypar CC 1 \($0) 0 127 absolute", ".mode 1dot"]
    }) -> [String] {
        (1 ... 56).flatMap { ["$encoder \($0)"] + properties($0) }
    }

    public static func encoderMap() throws -> HardwareMap {
        var map = HardwareMap()
        for number in 1 ... 56 {
            let control: BCRControlID = number <= 32
                ? .pushEncoder(group: (number - 1) / 8 + 1, (number - 1) % 8 + 1)
                : .encoder(row: (number - 33) / 8 + 1, (number - 33) % 8 + 1)
            try map.bind(control, to: .init(kind: .controlChange, channel: 0, number: UInt8(number)), ringMode: .oneDot)
        }
        return map
    }

    public static func encoderPreset(name: String? = nil) throws -> (dump: Data, hardwareMap: HardwareMap) {
        var header = ["$rev R1", "$preset"]
        if let name { header.append(".name '\(name)'") }
        header += [".egroups 4", ".fkeys on", ".lock off"]
        return (dump(header + encoderSections() + ["$end"]), try encoderMap())
    }
}
