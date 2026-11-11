import BCRAgentCore
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
        try original.write(to: url)
        let library = ConfigurationLibrary(url: url)
        XCTAssertNotNil(library.error)
        XCTAssertFalse(library.save(name: "test", configuration: .starter()))
        XCTAssertEqual(try Data(contentsOf: url), original)
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
