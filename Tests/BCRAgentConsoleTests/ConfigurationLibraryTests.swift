@testable import BCRFoundation
@testable import BCRCodexAdapter
@testable import BCRSurfaceDomain
@testable import BCRExamples
@testable import BCRConfigurationAdapter
@testable import BCRMCPAdapter
@testable import BCRHTTPTransport
@testable import BCRCoreMIDIDriver
@testable import BCRPersistenceAdapter
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
final class ConfigurationLibraryTests: XCTestCase {
    func testSaveReopenDeleteAndKeepCurrentConfigurationIndependent() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        let library = ConfigurationLibrary(url: url)
        let original = SurfaceConfiguration.starter()
        XCTAssertTrue(library.save(name: "My setup", configuration: original))
        XCTAssertFalse(library.save(name: "My setup", configuration: .robotArmDemo()))
        let reopened = ConfigurationLibrary(url: url)
        XCTAssertEqual(reopened.entries.first?.configuration, original)
        XCTAssertTrue(reopened.delete(try XCTUnwrap(reopened.entries.first?.id)))
        XCTAssertTrue(ConfigurationLibrary(url: url).entries.isEmpty)
        XCTAssertEqual(library.entries.count, 1)
    }

    func testCorruptFileCannotBeOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("corrupt".utf8)
        defer {
            try? FileManager.default
                .removeItem(at: url.appendingPathExtension("invalid.\(ContentDigest.sha256(original)).json"))
        }
        try original.write(to: url)
        let library = ConfigurationLibrary(url: url)
        XCTAssertNotNil(library.error)
        XCTAssertFalse(library.save(name: "test", configuration: .starter()))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFutureLibraryVersionAndExternalFutureReplacementStayProtected() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.json")
        let library = ConfigurationLibrary(url: url)
        XCTAssertTrue(library.save(name: "old", configuration: .starter()))
        let future = try JSONSerialization.data(withJSONObject: [["id": UUID().uuidString, "name": "future",
                                                                  "configuration": [
                                                                      "version": SurfaceConfiguration
                                                                          .currentVersion + 1,
                                                                      "unknownFutureAction": true
                                                                  ]]])
        try future.write(to: url)
        XCTAssertFalse(library.save(name: "new", configuration: .starter()))
        XCTAssertEqual(library.entries.count, 1)
        let reopened = ConfigurationLibrary(url: url)
        XCTAssertNotNil(reopened.error)
        XCTAssertFalse(reopened.save(name: "replacement", configuration: .starter()))
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["library.json"])
    }

    func testLibraryCorruptionIsBackedUpExactlyAndBackupConflictBlocksSave() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.json")
        let corrupt = Data("broken library".utf8)
        try corrupt.write(to: url)
        let library = ConfigurationLibrary(url: url)
        let backup = url.appendingPathExtension("invalid.\(ContentDigest.sha256(corrupt)).json")
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        XCTAssertFalse(library.save(name: "no overwrite", configuration: .starter()))
        try Data("conflict".utf8).write(to: backup)
        let blocked = ConfigurationLibrary(url: url)
        XCTAssertNotNil(blocked.error)
        XCTAssertFalse(blocked.save(name: "blocked", configuration: .starter()))
        XCTAssertEqual(try Data(contentsOf: backup), Data("conflict".utf8))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testLibrarySymlinkAndOversizeReadCannotEnableSaving() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "real")
        try Data("[]".utf8).write(to: real)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let linked = ConfigurationLibrary(url: link)
        XCTAssertNotNil(linked.error)
        XCTAssertFalse(linked.save(name: "no", configuration: .starter()))
        XCTAssertEqual(try Data(contentsOf: real), Data("[]".utf8))
        try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: real)
        let oversized = ConfigurationLibrary(url: real)
        XCTAssertNotNil(oversized.error)
        XCTAssertFalse(oversized.save(name: "no", configuration: .starter()))
        XCTAssertEqual(try real.resourceValues(forKeys: [.fileSizeKey]).fileSize, 4 * 1024 * 1024 + 1)
    }

    func testFailedSaveDoesNotPublishUndurableEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = ConfigurationLibrary(url: directory.appending(path: "library.json"))
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        XCTAssertFalse(library.save(name: "test", configuration: .starter()))
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertNotNil(library.error)
    }

    func testDecodingRejectsEmptySavedName() throws {
        let entry = SavedConfiguration(id: UUID(), name: " ", configuration: .starter())
        let data = try JSONEncoder().encode(entry)
        XCTAssertThrowsError(try JSONDecoder().decode(SavedConfiguration.self, from: data))
    }
}
