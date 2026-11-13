import BCRSurfaceDomain
import Foundation

/// Persistent endpoint identity without retaining CoreMIDI endpoint lifetimes or inventories.
struct PresetRestoreRoute: Codable, Equatable {
    var sourceID: Int32?
    var destinationID: Int32?
    var source: String?
    var destination: String?

    init(_ route: MIDIConnectionSnapshot) {
        sourceID = route.connectedSourceID
        destinationID = route.connectedDestinationID
        source = route.connectedSource
        destination = route.connectedDestination
    }

    func matches(_ route: MIDIConnectionSnapshot) -> Bool {
        route.isConnected && self == Self(route)
    }
}

/// Legacy fields remain readable. Missing safety context cannot authorize a device write.
/// History is stored as flat prior levels; all referenced preset files remain protected.
struct PresetRestorePoint: Codable, Equatable {
    var backupFile: String
    var hardwareMap: HardwareMap
    var createdAt: Date
    var route: PresetRestoreRoute?
    var expectedPreset: Data?
    var expectedHardwareMap: HardwareMap?
    var acknowledgedLines: Int?
    var history: [PresetRestorePoint]?
    var backupDigest: String?
    var restoreAttempted: Bool?

    var protectedFiles: Set<String> {
        Set([backupFile] + (history ?? []).flatMap { $0.protectedFiles })
    }

    var previous: PresetRestorePoint? {
        guard var levels = history, var previous = levels.popLast() else { return nil }
        previous.history = levels.isEmpty ? nil : levels
        return previous
    }

    static func history(retaining point: Self?) -> [Self]? {
        guard var point else { return nil }
        var levels = point.history ?? []
        point.history = nil
        levels.append(point)
        return levels
    }
}

struct PendingPresetRestore {
    let point: PresetRestorePoint
    let dump: Data
    let route: MIDIConnectionSnapshot
    let currentMap: HardwareMap
}

struct PresetOperationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
