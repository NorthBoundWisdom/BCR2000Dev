import BCRFoundation
import BCRCodexAdapter
import BCRSurfaceDomain
import BCRExamples
import BCRConfigurationAdapter
import BCRMCPAdapter
import BCRHTTPTransport
import BCRCoreMIDIDriver
import BCRPersistenceAdapter
import AppKit
import BCRPluginHost
import BCRProviderApplication
import BCRProviderMCPAdapter
import enum SurfacePluginContracts.IndicatorSemantic
import UniformTypeIdentifiers
import Combine
import Foundation

@MainActor
final class ConsoleRecoveryStore: ObservableObject {
    @Published private(set) var presetRestorePoint: PresetRestorePoint?
    private let restorePointStore: JSONFileStore<PresetRestorePoint>
    let presetBackupDirectory: URL
    init(directory: URL) {
        restorePointStore = JSONFileStore(fileURL: directory.appending(path: "preset-alignment-restore.json"))
        presetRestorePoint = try? restorePointStore.load()
        presetBackupDirectory = directory.appending(path: "Backups", directoryHint: .isDirectory)
    }

    func saveRestorePoint(_ candidate: PresetRestorePoint?) throws {
        let point = candidate?.bounded()
        if let point { try restorePointStore.save(point) }
        else if FileManager.default.fileExists(atPath: restorePointStore.fileURL.path) {
            try FileManager.default.removeItem(at: restorePointStore.fileURL)
        }
        presetRestorePoint = point
    }

    func saveBackup(_ dump: Data) throws -> URL {
        try PresetBackupStore(directory: presetBackupDirectory)
            .save(dump, protecting: presetRestorePoint?.protectedFiles ?? [])
    }

    func restoreDump(_ point: PresetRestorePoint) throws -> Data {
        guard point.backupFile == URL(fileURLWithPath: point.backupFile).lastPathComponent else {
            throw PresetOperationError("恢复备份路径无效。")
        }
        let dump = try Data(contentsOf: presetBackupDirectory.appending(path: point.backupFile))
        guard point.backupDigest == PresetBackupStore.digest(dump) else {
            throw PresetOperationError("恢复备份内容已改变，禁止写入。")
        }
        _ = try BCRPresetAlignment.prepare(dump: dump, hardwareMap: HardwareMap(), configuration: .neutral(),
                                           options: .init(completeButtons: false, ringModes: false,
                                                          buttonBehavior: false, lockPreset: false))
        _ = try BCRPresetAlignment.canonicalLines(of: dump)
        return dump
    }

    func matchesRestoreContext(_ current: Data, point: PresetRestorePoint, backup: Data) throws -> Bool {
        guard let expected = point.expectedPreset,
              try BCRPresetAlignment.deviceIdentifier(of: current) == BCRPresetAlignment.deviceIdentifier(of: backup)
        else { return false }
        let actual = try BCRPresetAlignment.identityLines(of: current)
        if actual == (try BCRPresetAlignment.identityLines(of: expected)) { return true }
        // A failed verification can leave the exact approved backup already on the device.
        // Retrying that known target is safe; arbitrary partial documents are never adopted.
        guard point.restoreAttempted == true else { return false }
        return actual == (try BCRPresetAlignment.identityLines(of: backup))
    }
}
