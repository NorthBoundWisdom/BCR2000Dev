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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try SurfaceConfigurationCodec.decode(Value.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeEncoded(encoder.encode(value))
    }

    public func writeEncoded(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
