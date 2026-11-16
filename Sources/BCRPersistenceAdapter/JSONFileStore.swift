import BCRFoundation
import BCRSurfaceDomain
import BCRConfigurationAdapter
import Foundation

/// Local JSON persistence under Application Support. Files here are device/user state and never
/// belong in git.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(applicationSupportFile name: String) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        fileURL = applicationSupport
            .appending(path: "BCRAgentConsole", directoryHint: .isDirectory)
            .appending(path: name)
    }

    /// Returns nil when the file does not exist yet; decoding failures are thrown.
    public func load() throws -> Value? {
        guard let data = try readEncoded() else { return nil }
        if let supportedVersion { try LocalDataFile.rejectFutureVersion(in: data, supported: supportedVersion) }
        return try SurfaceConfigurationCodec.decode(Value.self, from: data)
    }

    private var supportedVersion: Int? {
        if Value.self == SurfaceConfiguration.self { return SurfaceConfiguration.currentVersion }
        if Value.self == HardwareMap.self { return HardwareMap.currentVersion }
        return nil
    }

    public static var maximumBytes: Int { 4 * 1_024 * 1_024 }

    public func readEncoded() throws -> Data? {
        try LocalDataFile.read(fileURL, maximumBytes: Self.maximumBytes)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeEncoded(encoder.encode(value))
    }

    public func writeEncoded(_ data: Data) throws {
        try writeEncoded(data, expectedOriginal: nil, requireUnchanged: false)
    }

    public func writeEncoded(_ data: Data, expectedOriginal: Data?, requireUnchanged: Bool) throws {
        if let supportedVersion { try LocalDataFile.rejectFutureVersion(in: data, supported: supportedVersion) }
        try LocalDataFile.replace(data, at: fileURL, maximumBytes: Self.maximumBytes) { original in
            if requireUnchanged, original != expectedOriginal { throw LocalDataFileError.changedFile }
            if let original,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let supported = object["version"] as? Int
            {
                try LocalDataFile.rejectFutureVersion(in: original, supported: supported)
            }
        }
    }
}
