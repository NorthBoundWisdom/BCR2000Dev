import BCRPersistenceAdapter
import BCRSurfaceDomain
import Foundation

/// Owns only validated, regular JSON files in the historical map archive namespace.
struct PresetMapArchiveStore {
    static let recentCount = 5
    let directory: URL

    func save(_ map: HardwareMap, now: Date = .now) throws -> URL {
        let url = directory.appending(path: "hardware-map-before-restore-\(UUID().uuidString).json")
        try JSONFileStore<HardwareMap>(fileURL: url).save(map)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: now],
                                              ofItemAtPath: url.path)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey
            ]
        ).filter { file in
            guard file.lastPathComponent.range(
                of: #"^hardware-map-before-restore-[0-9A-Fa-f-]{36}\.json$"#, options: .regularExpression
            ) != nil else { return false }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
                && (try? JSONFileStore<HardwareMap>(fileURL: file).load()) != nil
        }
        // Repair permissions on older managed archives before applying the retention limit.
        for file in files { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let ordered = try files.sorted { left, right in
            if left == url { return right != url }
            if right == url { return false }
            let l = try left.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let r = try right.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            return l == r ? left.lastPathComponent < right.lastPathComponent : l > r
        }
        for file in ordered.dropFirst(Self.recentCount) { try FileManager.default.removeItem(at: file) }
        return url
    }
}
