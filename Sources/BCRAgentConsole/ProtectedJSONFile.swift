import BCRAgentCore
import CryptoKit
import Foundation

struct ProtectedFileRead<Value: Sendable>: Sendable {
    let value: Value
    let message: String?
    let failed: Bool
}

struct ConfigurationFileError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// A failed load never writes the original. Every later save protects invalid/old data first.
struct ProtectedJSONFile<Value: Codable & Sendable>: Sendable {
    let store: JSONFileStore<Value>
    let title: String
    let normalize: @Sendable (Value) throws -> Value
    let version: @Sendable (Value) -> Int
    let fallback: @Sendable () -> Value
    private let writeBackup: @Sendable (Data, URL) throws -> Void

    init(store: JSONFileStore<Value>, title: String,
         normalize: @escaping @Sendable (Value) throws -> Value,
         version: @escaping @Sendable (Value) -> Int,
         fallback: @escaping @Sendable () -> Value,
         writeBackup: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(
             to: $1,
             options: .withoutOverwriting
         ) })
    {
        self.store = store
        self.title = title
        self.normalize = normalize
        self.version = version
        self.fallback = fallback
        self.writeBackup = writeBackup
    }

    static var maximumBytes: Int { 4 * 1_024 * 1_024 }

    func load() -> ProtectedFileRead<Value> {
        do {
            guard let data = try existingData() else { return .init(value: fallback(), message: nil, failed: false) }
            let original = try JSONDecoder().decode(Value.self, from: data)
            let value = try normalize(original)
            let message = version(original) != version(value)
                ? "\(title)已从 v\(version(original)) 迁移到 v\(version(value))；原文件尚未改写。"
                : nil
            return .init(value: value, message: message, failed: false)
        } catch {
            let failure = error.localizedDescription
            do {
                let backup = try backupExisting(kind: "invalid")
                return .init(
                    value: fallback(),
                    message: "\(title)读取/校验失败：\(failure)。已载入安全初始配置，原文件保留；备份：\(backup?.lastPathComponent ?? "文件不存在")。",
                    failed: true
                )
            } catch {
                return .init(
                    value: fallback(),
                    message: "\(title)读取失败：\(failure)。备份也失败：\(error.localizedDescription)。原文件未改写，后续保存将在保护原文件前被阻止。",
                    failed: true
                )
            }
        }
    }

    func save(_ value: Value) throws {
        let normalized = try normalize(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        guard data.count <= Self.maximumBytes
        else { throw ConfigurationFileError(reason: "\(title)超过 4 MiB 上限，未覆盖原文件") }
        if let original = try existingData() {
            var needsProtection = false
            do {
                let decoded = try JSONDecoder().decode(Value.self, from: original)
                _ = try normalize(decoded)
                needsProtection = version(decoded) != version(normalized)
            } catch { needsProtection = true }
            if needsProtection { _ = try backupExisting(kind: "backup") }
        }
        try store.writeEncoded(data)
    }

    private func existingData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: store.fileURL.path) else { return nil }
        let data = try Data(contentsOf: store.fileURL, options: .mappedIfSafe)
        guard data.count <= Self.maximumBytes
        else { throw ConfigurationFileError(reason: "\(title)原文件超过 4 MiB，保留原文件并拒绝覆盖") }
        return data
    }

    @discardableResult
    private func backupExisting(kind: String) throws -> URL? {
        guard let data = try existingData() else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
        let url = store.fileURL.appendingPathExtension("\(kind).\(digest).json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { throw ConfigurationFileError(reason: "备份冲突，未覆盖原文件") }
        } else {
            try writeBackup(data, url)
        }
        guard try Data(contentsOf: url) == data else { throw ConfigurationFileError(reason: "备份校验失败，未覆盖原文件") }
        return url
    }
}

extension ProtectedJSONFile where Value == SurfaceConfiguration {
    static func configuration(_ store: JSONFileStore<Value>) -> Self {
        Self(store: store, title: "功能配置", normalize: { try $0.migrated() },
             version: { $0.version }, fallback: { .robotArmDemo() })
    }
}

extension ProtectedJSONFile where Value == HardwareMap {
    static func hardware(_ store: JSONFileStore<Value>) -> Self {
        Self(store: store, title: "硬件映射", normalize: { try $0.migrated() },
             version: { $0.version }, fallback: { HardwareMap() })
    }
}

enum ConfigurationTransfer {
    static func decode(_ data: Data) throws -> SurfaceConfiguration {
        guard data.count <= ProtectedJSONFile<SurfaceConfiguration>.maximumBytes else {
            throw ConfigurationFileError(reason: "导入文件超过 4 MiB")
        }
        return try JSONDecoder().decode(SurfaceConfiguration.self, from: data).migrated()
    }

    static func encode(_ configuration: SurfaceConfiguration) throws -> Data {
        let current = try configuration.migrated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(current)
        guard data.count <= ProtectedJSONFile<SurfaceConfiguration>.maximumBytes else {
            throw ConfigurationFileError(reason: "导出配置超过 4 MiB")
        }
        return data
    }
}
