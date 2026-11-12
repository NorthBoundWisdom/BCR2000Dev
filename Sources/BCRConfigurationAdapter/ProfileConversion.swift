import BCRFoundation
import BCRSurfaceDomain
import Foundation

/// Offline conversion of explicitly captured device data; no device writes or source layout contract.
public enum ProfileConversion {
    public static func prepareButtons(capture: URL,
                                      profile: URL) throws -> (mappings: Int, missing: Int, unsupported: Int)
    {
        let map = try JSONDecoder().decode(
            HardwareMap.self,
            from: Data(contentsOf: profile.appending(path: "hardware-map.json"))
        )
        let plan = try BCRPresetButtonLearning.prepare(
            dump: Data(contentsOf: capture.appending(path: "current-preset.syx")),
            existingMap: map
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = capture.appending(path: "learned-button-hardware-map.json")
        try encoder.encode(plan.hardwareMap).write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return (plan.hardwareMap.boundCount, plan.unconfigured.count, plan.unsupported.count)
    }

    private struct SnapshotEntry: Decodable { let channel: UInt8; let number: UInt8; let value: UInt8 }
    public static func prepare(capture: URL, profile: URL) throws -> (mappings: Int, parameters: Int) {
        let decoder = JSONDecoder()
        let mapURL = profile.appending(path: "hardware-map.json")
        let configURL = profile.appending(path: "surface-configuration.json")
        let map = try FileManager.default.fileExists(atPath: mapURL.path)
            ? decoder.decode(HardwareMap.self, from: Data(contentsOf: mapURL)).migrated() : HardwareMap()
        let configuration = try FileManager.default.fileExists(atPath: configURL.path)
            ? SurfaceConfigurationCodec.decode(Data(contentsOf: configURL)).migrated()
            : SurfaceConfiguration.neutral()
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
        return (plan.hardwareMap.boundCount, plan.configuration.parameters.count)
    }
}
