import BCRSurfaceDomain
import CryptoKit
import Foundation

/// Private preset history: deduplicate by bytes and keep five recent backups plus the active restore point.
struct PresetBackupStore {
    static let recentCount = 5
    let directory: URL

    func save(_ dump: Data, protecting restoreFile: String?, now: Date = .now) throws -> URL {
        try save(dump, protecting: Set(restoreFile.map { [$0] } ?? []), now: now)
    }

    func save(_ dump: Data, protecting restoreFiles: Set<String>, now: Date = .now) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidates = try managedBackups()
        let existing = try candidates.first { try Data(contentsOf: $0) == dump }
        let url = existing ?? directory.appending(path: "temporary-preset-sha256-\(Self.digest(dump)).syx")
        if existing == nil { try dump.write(to: url, options: .withoutOverwriting) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .modificationDate: now],
            ofItemAtPath: url.path
        )
        let recent = try managedBackups().sorted {
            // The backup just read is newest logically, even after a wall-clock correction.
            if $0 == url { return $1 != url }
            if $1 == url { return false }
            let left = try $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let right = try $1.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left > right
        }
        let kept = Set(recent.prefix(Self.recentCount).map(\.lastPathComponent))
        for candidate in recent where !kept.contains(candidate.lastPathComponent)
            && !restoreFiles.contains(candidate.lastPathComponent)
        {
            try FileManager.default.removeItem(at: candidate)
        }
        return url
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func managedBackups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).map { directory.appending(path: $0.lastPathComponent) }.filter { url in
            let name = url.lastPathComponent
            let hashed = name
                .range(of: #"^temporary-preset-sha256-[0-9a-f]{64}\.syx$"#, options: .regularExpression) != nil
            let legacy = name.range(of: #"^temporary-preset-[0-9]{10,}\.syx$"#, options: .regularExpression) != nil
            guard hashed || legacy else { return false }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
            let data = try Data(contentsOf: url)
            if hashed { return name == "temporary-preset-sha256-\(Self.digest(data)).syx" }
            // Only adopt the former timestamp namespace when its bytes are a complete temporary preset.
            // Unknown names, corrupt files, directories and symlinks never enter cleanup.
            return (try? BCRPresetAlignment.prepare(
                dump: data, hardwareMap: HardwareMap(), configuration: .neutral(),
                options: .init(completeButtons: false, ringModes: false, buttonBehavior: false, lockPreset: false)
            )) != nil
        }
    }
}
