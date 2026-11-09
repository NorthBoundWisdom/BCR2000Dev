import BCRAgentCore
import Foundation

/// Local JSON persistence under Application Support. Files here are device/user state and never
/// belong in git.
struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(applicationSupportFile name: String) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        fileURL = applicationSupport
            .appending(path: "BCRAgentConsole", directoryHint: .isDirectory)
            .appending(path: name)
    }

    /// Returns nil when the file does not exist yet; decoding failures are thrown.
    func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: fileURL))
    }

    func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeEncoded(encoder.encode(value))
    }

    func writeEncoded(_ data: Data) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

struct ConsoleStores: Sendable {
    let hardwareMap: JSONFileStore<HardwareMap>
    let configuration: JSONFileStore<SurfaceConfiguration>

    static let standard = ConsoleStores(
        hardwareMap: JSONFileStore(applicationSupportFile: "hardware-map.json"),
        configuration: JSONFileStore(applicationSupportFile: "surface-configuration.json")
    )

    static func temporary() -> ConsoleStores {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bcr-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ConsoleStores(
            hardwareMap: JSONFileStore(fileURL: directory.appending(path: "hardware-map.json")),
            configuration: JSONFileStore(fileURL: directory.appending(path: "surface-configuration.json"))
        )
    }
}
