import Foundation

public struct CodexStoredModelCatalog: Codable, Equatable, Sendable {
    public let models: [CodexModelCapability]
    public let updatedAt: Date

    public init(models: [CodexModelCapability], updatedAt: Date = .now) {
        self.models = models
        self.updatedAt = updatedAt
    }
}

public actor CodexModelCatalogStore {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.fileURL = supportDirectory
            .appending(path: "BCRAgentConsole", directoryHint: .isDirectory)
            .appending(path: "codex-model-catalog.json")
    }

    public func load() async throws -> [CodexModelCapability] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(CodexStoredModelCatalog.self, from: data)
        return decoded.models
    }

    public func save(_ models: [CodexModelCapability]) async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let payload = CodexStoredModelCatalog(models: models)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: .atomic)
    }
}
