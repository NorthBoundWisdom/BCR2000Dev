import BCRAgentCore
import Foundation

struct ControllerProfileStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.fileURL = applicationSupport
                .appending(path: "BCRAgentConsole", directoryHint: .isDirectory)
                .appending(path: "controller-profile.json")
        }
    }

    func load() throws -> ControllerProfile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ControllerProfile()
        }
        let data = try Data(contentsOf: fileURL)
        let profile = try JSONDecoder().decode(ControllerProfile.self, from: data)
        guard profile.version == ControllerProfile.currentVersion else {
            return ControllerProfile()
        }
        return profile
    }

    func save(_ profile: ControllerProfile) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try data.write(to: fileURL, options: .atomic)
    }
}
