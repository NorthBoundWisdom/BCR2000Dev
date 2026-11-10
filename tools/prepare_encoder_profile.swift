import Foundation

/// Compile with BCRAgentCore sources; stages validated files without replacing user files.
@main
struct PrepareEncoderProfile {
    struct SnapshotEntry: Decodable {
        let channel: UInt8
        let number: UInt8
        let value: UInt8
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            throw BCRPresetEncoderLearning.Failure
                .invalid("用法：prepare_encoder_profile <capture-directory> <profile-directory>")
        }
        let capture = URL(fileURLWithPath: args[1], isDirectory: true)
        let profile = URL(fileURLWithPath: args[2], isDirectory: true)
        let decoder = JSONDecoder()
        let mapURL = profile.appending(path: "hardware-map.json")
        let configURL = profile.appending(path: "surface-configuration.json")
        let map = try FileManager.default.fileExists(atPath: mapURL.path)
            ? decoder.decode(HardwareMap.self, from: Data(contentsOf: mapURL)).migrated() : HardwareMap()
        let configuration = try FileManager.default.fileExists(atPath: configURL.path)
            ? decoder.decode(SurfaceConfiguration.self, from: Data(contentsOf: configURL)).migrated()
            : SurfaceConfiguration.robotArmDemo()
        let entries = try decoder.decode(
            [SnapshotEntry].self,
            from: Data(contentsOf: capture.appending(path: "snapshot.json"))
        )
        var snapshot: [MIDIControlID: UInt8] = [:]
        for entry in entries {
            guard entry.channel < 16, entry.number < 128, entry.value < 128 else {
                throw BCRPresetEncoderLearning.Failure.invalid("快照数值无效")
            }
            let midi = MIDIControlID(kind: .controlChange, channel: entry.channel, number: entry.number)
            guard snapshot.updateValue(entry.value, forKey: midi) == nil else {
                throw BCRPresetEncoderLearning.Failure.invalid("快照身份重复")
            }
        }
        let plan = try BCRPresetEncoderLearning.prepare(
            dump: Data(contentsOf: capture.appending(path: "current-preset.syx")),
            snapshot: snapshot, existingMap: map, configuration: configuration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (name, data) in [
            ("learned-hardware-map.json", try encoder.encode(plan.hardwareMap)),
            ("learned-surface-configuration.json", try encoder.encode(plan.configuration))
        ] {
            let destination = capture.appending(path: name)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw BCRPresetEncoderLearning.Failure.invalid("暂存文件已存在")
            }
            try data.write(to: destination, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        print(
            "Staged \(plan.hardwareMap.boundCount) mappings and \(plan.configuration.parameters.count) parameters; original profile unchanged"
        )
    }
}
