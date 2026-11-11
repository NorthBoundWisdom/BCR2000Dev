import BCRAgentCore
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
            if FileManager.default.fileExists(atPath: url.path),
               try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 4 * 1024 * 1024
            {
                throw CocoaError(.fileReadTooLarge)
            }
            let loaded = try store.load() ?? []
            guard Set(loaded.map(\.id)).count == loaded.count,
                  Set(loaded.map(\.name)).count == loaded.count else { throw CocoaError(.coderReadCorrupt) }
            for entry in loaded { try entry.configuration.validate() }
            entries = loaded
        } catch {
            writable = false
            self.error = error.localizedDescription
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
            try store.writeEncoded(data)
            entries = candidate
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
