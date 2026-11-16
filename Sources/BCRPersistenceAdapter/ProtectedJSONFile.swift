import BCRFoundation
import BCRSurfaceDomain
import BCRConfigurationAdapter
import BCRExamples
import Foundation

public struct ProtectedFileRead<Value: Sendable>: Sendable {
    public let value: Value
    public let message: String?
    public let failed: Bool
}

public struct ConfigurationFileError: Error, LocalizedError {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// A failed load never writes the original. Every later save protects invalid/old data first.
public struct ProtectedJSONFile<Value: Codable & Sendable>: Sendable {
    public let store: JSONFileStore<Value>
    let title: String
    let normalize: @Sendable (Value) throws -> Value
    let version: @Sendable (Value) -> Int
    let fallback: @Sendable () -> Value
    private let writeBackup: @Sendable (Data, URL) throws -> Void

    public init(store: JSONFileStore<Value>, title: String,
                normalize: @escaping @Sendable (Value) throws -> Value,
                version: @escaping @Sendable (Value) -> Int,
                fallback: @escaping @Sendable () -> Value,
                writeBackup: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
                    let file = try CaptureEvidenceFile(url: url)
                    defer { try? file.close() }
                    try file.write(data)
                    try file.synchronize()
                })
    {
        self.store = store
        self.title = title
        self.normalize = normalize
        self.version = version
        self.fallback = fallback
        self.writeBackup = writeBackup
    }

    public static var maximumBytes: Int { 4 * 1_024 * 1_024 }

    public func load() -> ProtectedFileRead<Value> {
        do {
            guard let data = try existingData() else { return .init(value: fallback(), message: nil, failed: false) }
            try LocalDataFile.rejectFutureVersion(in: data, supported: version(fallback()))
            let original = try SurfaceConfigurationCodec.decode(Value.self, from: data)
            let value = try normalize(original)
            let message = version(original) != version(value)
                ? L10n.text("\(title)已从 v\(version(original)) 迁移到 v\(version(value))；原文件尚未改写。")
                : nil
            return .init(value: value, message: message, failed: false)
        } catch LocalDataFileError.newerVersion(let version) {
            return .init(
                value: fallback(),
                message: LocalDataFileError.newerVersion(version).localizedDescription,
                failed: true
            )
        } catch {
            let failure = error.localizedDescription
            do {
                let backup = try backupExisting(kind: "invalid")
                return .init(
                    value: fallback(),
                    message: L10n
                        .text(
                            "\(title)读取/校验失败：\(failure)。已载入安全初始配置，原文件保留；备份：\(backup?.lastPathComponent ?? L10n.text("文件不存在"))。"
                        ),
                    failed: true
                )
            } catch {
                return .init(
                    value: fallback(),
                    message: L10n
                        .text("\(title)读取失败：\(failure)。备份也失败：\(error.localizedDescription)。原文件未改写，后续保存将在保护原文件前被阻止。"),
                    failed: true
                )
            }
        }
    }

    public func save(_ value: Value) throws {
        let normalized = try normalize(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        guard data.count <= Self.maximumBytes
        else { throw ConfigurationFileError(reason: L10n.text("\(title)超过 4 MiB 上限，未覆盖原文件")) }
        let original = try existingData()
        if let original {
            try LocalDataFile.rejectFutureVersion(in: original, supported: version(normalized))
            var needsProtection = false
            do {
                let decoded = try SurfaceConfigurationCodec.decode(Value.self, from: original)
                _ = try normalize(decoded)
                needsProtection = version(decoded) != version(normalized)
            } catch { needsProtection = true }
            if needsProtection { _ = try backupExisting(kind: "backup") }
        }
        try store.writeEncoded(data, expectedOriginal: original, requireUnchanged: true)
    }

    private func existingData() throws -> Data? {
        try store.readEncoded()
    }

    @discardableResult
    private func backupExisting(kind: String) throws -> URL? {
        guard let data = try existingData() else { return nil }
        return try LocalDataFile.contentBackup(data, original: store.fileURL, kind: kind,
                                               maximumBytes: Self.maximumBytes, write: writeBackup)
    }
}

extension ProtectedJSONFile where Value == SurfaceConfiguration {
    /// `preset` is used only when no valid saved configuration exists.
    public static func configuration(_ store: JSONFileStore<Value>, preset: ConfigurationPreset = .starter) -> Self {
        Self(store: store, title: L10n.text("功能配置"), normalize: { try $0.migrated() },
             version: { $0.version }, fallback: { preset.makeConfiguration() })
    }
}

extension ProtectedJSONFile where Value == HardwareMap {
    public static func hardware(_ store: JSONFileStore<Value>) -> Self {
        Self(store: store, title: L10n.text("硬件映射"), normalize: { try $0.migrated() },
             version: { $0.version }, fallback: { HardwareMap() })
    }
}

public enum ConfigurationTransfer {
    public static func decode(_ data: Data) throws -> SurfaceConfiguration {
        guard data.count <= ProtectedJSONFile<SurfaceConfiguration>.maximumBytes else {
            throw ConfigurationFileError(reason: L10n.text("导入文件超过 4 MiB"))
        }
        return try SurfaceConfigurationCodec.decode(SurfaceConfiguration.self, from: data).migrated()
    }

    public static func encode(_ configuration: SurfaceConfiguration) throws -> Data {
        let current = try configuration.migrated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(current)
        guard data.count <= ProtectedJSONFile<SurfaceConfiguration>.maximumBytes else {
            throw ConfigurationFileError(reason: L10n.text("导出配置超过 4 MiB"))
        }
        return data
    }
}
