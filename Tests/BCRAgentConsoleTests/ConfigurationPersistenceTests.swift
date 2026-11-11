import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

@MainActor
final class ConfigurationPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stores(_ directory: URL) -> ConsoleStores {
        ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "hardware-map.json")),
                      configuration: JSONFileStore(fileURL: directory.appending(path: "surface-configuration.json")))
    }

    func testPageWarningDoesNotHideProgramSaveFailure() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = stores(directory)
        let model = ConsoleViewModel(stores: stores, startsMIDI: false)
        try FileManager.default.createDirectory(at: stores.configuration.fileURL, withIntermediateDirectories: false)
        var candidate = model.configuration
        try candidate.addPage(.init(id: "p", name: "Page", assignments: []))
        try model.updatePrograms(candidate)
        XCTAssertNotNil(model.configuration.pageNavigationWarning)
        XCTAssertEqual(model.notice?.level, .error)
    }

    func testInvalidLoadPreservesOriginalAndBacksUpExactBytesBeforeLaterSave() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = stores(directory).configuration
        let original = Data("{ invalid user configuration".utf8)
        try original.write(to: store.fileURL)
        let file = ProtectedJSONFile.configuration(store)
        let read = file.load()
        XCTAssertTrue(read.failed)
        XCTAssertNotNil(read.message)
        XCTAssertEqual(read.value, .starter())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        let copies = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0 != store.fileURL }
        XCTAssertTrue(try copies.contains { try Data(contentsOf: $0) == original })
        try file.save(read.value)
        XCTAssertEqual(try store.load(), read.value)
        XCTAssertTrue(try copies.contains { try Data(contentsOf: $0) == original })
    }

    func testFailedBackupBlocksSaveAndKeepsInvalidOriginal() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = stores(directory).configuration
        let original = Data("unrecoverable test source".utf8)
        try original.write(to: store.fileURL)
        let file = ProtectedJSONFile(
            store: store, title: "Test", normalize: { try $0.migrated() }, version: { $0.version },
            fallback: { .robotArmDemo() },
            writeBackup: { _, _ in throw ConfigurationFileError(reason: "test backup denied") }
        )
        let loaded = file.load()
        XCTAssertTrue(loaded.failed)
        XCTAssertTrue(loaded.message?.contains(L10n.language == .chinese ? "备份" : "Backup") == true)
        XCTAssertThrowsError(try file.save(.robotArmDemo()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testMigrationIsVisibleAndOriginalIsUntouchedUntilExplicitSave() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = stores(directory).configuration
        var old = SurfaceConfiguration.robotArmDemo()
        old.version = 1
        let data = try JSONEncoder().encode(old)
        try data.write(to: store.fileURL)
        let file = ProtectedJSONFile.configuration(store)
        let read = file.load()
        XCTAssertFalse(read.failed)
        XCTAssertTrue(read.message?.contains(L10n.language == .chinese ? "迁移" : "migrated") == true)
        XCTAssertEqual(read.value.version, SurfaceConfiguration.currentVersion)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), data)
        try file.save(read.value)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0 != store.fileURL }
        XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == data })
    }

    func testInvalidImportDoesNotReplaceConfigurationParametersOrMapping() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConsoleViewModel(stores: stores(directory), startsMIDI: false)
        model.setParameter("general.1", to: 42)
        XCTAssertEqual(model.engine.value(of: "general.1"), 42)
        let before = model.configuration
        let values = model.engine.parameterValues
        let map = model.engine.hardwareMap
        XCTAssertFalse(model.installConfiguration(SurfaceConfiguration(name: "")))
        XCTAssertEqual(model.configuration, before)
        XCTAssertEqual(model.engine.parameterValues, values)
        XCTAssertEqual(model.engine.hardwareMap, map)
        XCTAssertEqual(model.notice?.level, .error)
        let bad = directory.appending(path: "bad-import.json")
        try Data("[]".utf8).write(to: bad)
        XCTAssertThrowsError(try model.readConfiguration(from: bad))
        XCTAssertEqual(model.configuration, before)
    }

    func testImportSaveFailureDoesNotReplaceLiveState() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appending(path: "not-a-directory")
        try Data("file".utf8).write(to: blocked)
        let model = ConsoleViewModel(stores: stores(blocked), startsMIDI: false)
        let before = model.configuration
        var candidate = before
        candidate.name = "New"
        XCTAssertFalse(model.installConfiguration(candidate))
        XCTAssertEqual(model.configuration, before)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("file".utf8))
    }

    func testValidImportExportsOnlyVersionedConfigurationAndKeepsHardwareMap() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConsoleViewModel(stores: stores(directory), startsMIDI: false)
        let map = model.engine.hardwareMap
        var imported = SurfaceConfiguration.robotArmDemo()
        imported.name = "Imported"
        XCTAssertTrue(model.installConfiguration(imported))
        XCTAssertEqual(model.configuration.name, "Imported")
        XCTAssertEqual(model.engine.hardwareMap, map)
        let url = directory.appending(path: "export.json")
        try model.exportConfiguration(to: url)
        let data = try Data(contentsOf: url)
        let raw = try JSONDecoder().decode(JSONValue.self, from: data).objectValue!
        XCTAssertEqual(Set(raw.keys), Set(["version", "name", "parameters", "assignments", "pages", "macros"]))
        XCTAssertNil(raw["hardwareMap"])
        XCTAssertNil(raw["token"])
        XCTAssertNil(raw["parameterValues"])
        XCTAssertEqual(try ConfigurationTransfer.decode(data), imported)
    }

    func testOversizedOriginalIsNeverReplaced() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = stores(directory).configuration
        let original = Data(repeating: 65, count: ProtectedJSONFile<SurfaceConfiguration>.maximumBytes + 1)
        try original.write(to: store.fileURL)
        let file = ProtectedJSONFile.configuration(store)
        XCTAssertTrue(file.load().failed)
        XCTAssertThrowsError(try file.save(.robotArmDemo()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testInvalidHardwareMapIsPreservedAndNeverFallsBackToMockPreset() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = stores(directory).hardwareMap
        let original = Data("{\"version\":3,\"entries\":[{\"control\":{\"section\":\"encoder\",\"row\":1,\"index\":1},\"midi\":{\"kind\":\"controlChange\",\"channel\":16,\"number\":1}}]}"
            .utf8)
        try original.write(to: store.fileURL)
        let result = ProtectedJSONFile.hardware(store).load()
        XCTAssertTrue(result.failed)
        XCTAssertEqual(result.value.boundCount, 0)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testRetrySaveClearsVisibleStorageFailureWithoutRequiringAnotherEdit() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appending(path: "parent")
        try Data("file".utf8).write(to: blocked)
        let storage = stores(blocked)
        let model = ConsoleViewModel(stores: storage, startsMIDI: false)
        model.loadPreset(.robotArm)
        XCTAssertEqual(model.notice?.action, .retryConfigurationSave)
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        model.performNoticeAction(.retryConfigurationSave)
        XCTAssertEqual(model.notice?.level, .info)
        XCTAssertEqual(try storage.configuration.load(), model.configuration)
    }

    func testClampedDefinitionSaveCanBeAdoptedAsCleanDraft() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConsoleViewModel(stores: stores(directory), startsMIDI: false)
        let id = try XCTUnwrap(model.createParameter())
        let initial = ParameterDefinition(id: id, name: "Test", defaultValue: 55)
        _ = model.updateParameter(initial)
        var state = ParameterDraftState(initial)
        state.value.maximum = 40
        let applied = try XCTUnwrap(model.updateParameter(state.value))
        XCTAssertEqual(applied.defaultValue, 40)
        state.reload(applied)
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.conflict)
    }

    func testV3HardwareMapMigratesVisiblyAndBacksUpExactBytes() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = stores(directory).hardwareMap
        let map = HardwareMap(version: 3, entries: [.init(control: .encoder(row: 1, 1),
                                                          midi: .init(kind: .controlChange, channel: 0, number: 5))])
        let original = try JSONEncoder().encode(map)
        try original.write(to: store.fileURL)
        let file = ProtectedJSONFile.hardware(store)
        let read = file.load()
        XCTAssertFalse(read.failed)
        XCTAssertTrue(read.message?.contains(L10n.language == .chinese ? "迁移" : "migrated") == true)
        XCTAssertEqual(read.value.version, 4)
        XCTAssertEqual(read.value.entries, map.entries)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        try file.save(read.value)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0 != store.fileURL }
        XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == original })
    }
}
