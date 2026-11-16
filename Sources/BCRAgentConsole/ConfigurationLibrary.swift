import BCRFoundation
import BCRCodexAdapter
import BCRSurfaceDomain
import BCRExamples
import BCRConfigurationAdapter
import BCRMCPAdapter
import BCRHTTPTransport
import BCRCoreMIDIDriver
import BCRPersistenceAdapter
import Foundation
import Combine

struct SavedConfiguration: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let configuration: SurfaceConfiguration

    init(id: UUID, name: String, configuration: SurfaceConfiguration) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey { case id, name, configuration }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: c,
                debugDescription: "Empty saved configuration name"
            )
        }
        configuration = try c.decode(SurfaceConfiguration.self, forKey: .configuration)
    }
}

@MainActor
final class ConfigurationLibrary: ObservableObject {
    @Published private(set) var entries: [SavedConfiguration] = []
    @Published private(set) var error: String?
    private let store: JSONFileStore<[SavedConfiguration]>
    private var writable = true

    init(url: URL) {
        store = JSONFileStore(fileURL: url)
        do {
            entries = try readValidated().entries
        } catch {
            writable = false
            self.error = error.localizedDescription
        }
    }

    private func readValidated() throws -> (entries: [SavedConfiguration], data: Data?) {
        guard let data = try store.readEncoded() else { return ([], nil) }
        do {
            // Check each configuration envelope before decoding future action/field shapes.
            if let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for object in objects {
                    if let configuration = object["configuration"] as? [String: Any] {
                        try LocalDataFile.rejectFutureVersion(in: JSONSerialization.data(withJSONObject: configuration),
                                                              supported: SurfaceConfiguration.currentVersion)
                    }
                }
            }
            let loaded = try SurfaceConfigurationCodec.decode([SavedConfiguration].self, from: data)
            guard Set(loaded.map(\.id)).count == loaded.count,
                  Set(loaded.map(\.name)).count == loaded.count else { throw CocoaError(.coderReadCorrupt) }
            for entry in loaded { try entry.configuration.validate() }
            return (loaded, data)
        } catch LocalDataFileError.newerVersion(let version) {
            throw LocalDataFileError.newerVersion(version)
        } catch {
            _ = try LocalDataFile.contentBackup(data, original: store.fileURL, kind: "invalid",
                                                maximumBytes: JSONFileStore<[SavedConfiguration]>.maximumBytes)
            throw error
        }
    }

    @discardableResult
    func save(name: String, configuration: SurfaceConfiguration) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = L10n.text("配置名称不能为空"); return false }
        guard !entries.contains(where: { $0.name == name }) else {
            error = L10n.text("配置名称已存在"); return false
        }
        do { try configuration.validate() }
        catch { self.error = error.localizedDescription; return false }
        return persist(entries + [.init(id: UUID(), name: name, configuration: configuration)])
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool { persist(entries.filter { $0.id != id }) }

    private func persist(_ candidate: [SavedConfiguration]) -> Bool {
        guard writable else { return false }
        do {
            let data = try JSONEncoder().encode(candidate)
            guard data.count <= 4 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            let original = try readValidated().data
            try store.writeEncoded(data, expectedOriginal: original, requireUnchanged: true)
            entries = candidate
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
