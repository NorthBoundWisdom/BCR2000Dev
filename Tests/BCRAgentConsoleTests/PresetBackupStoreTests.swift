import BCRTestSupport
import Foundation
import XCTest
@testable import BCRAgentConsole

final class PresetBackupStoreTests: XCTestCase {
    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testEqualContentsReuseOneFileWithPrivatePermissions() throws {
        let directory = try temporary()
        let store = PresetBackupStore(directory: directory)
        let data = Data("same preset".utf8)
        let first = try store.save(data, protecting: nil)
        for _ in 0 ..< 3 { XCTAssertEqual(try store.save(data, protecting: nil), first) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        XCTAssertEqual(try Data(contentsOf: first), data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int, 0o600)
    }

    func testRetentionPinsRestorePointAndLeavesUnownedFilesAndSymlinksUntouched() throws {
        let directory = try temporary()
        let store = PresetBackupStore(directory: directory)
        let first = try store.save(Data([0]), protecting: nil, now: Date(timeIntervalSince1970: 0))
        let unrelated = directory.appending(path: "my-preset.syx")
        let corruptLegacy = directory.appending(path: "temporary-preset-1234567890.syx")
        try Data("personal".utf8).write(to: unrelated)
        try Data("incomplete".utf8).write(to: corruptLegacy)
        let link = directory.appending(path: "temporary-preset-1234567891.syx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        var history = [URL]()
        for value in 1 ... 9 {
            history.append(try store.save(Data([UInt8(value)]), protecting: first.lastPathComponent,
                                          now: Date(timeIntervalSince1970: Double(value))))
        }
        XCTAssertEqual(try Data(contentsOf: first), Data([0]))
        for url in history.prefix(4) { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
        for url in history
            .suffix(PresetBackupStore.recentCount) { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("personal".utf8))
        XCTAssertEqual(try Data(contentsOf: corruptLegacy), Data("incomplete".utf8))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testValidLegacyTimestampBackupIsReused() throws {
        let directory = try temporary()
        let lines = ["$rev R1", "$preset", ".egroups 4", ".lock off", "$end"]
        let data = BCLFixtures.dump(lines)
        let legacy = directory.appending(path: "temporary-preset-1794500000.syx")
        try data.write(to: legacy)
        XCTAssertEqual(
            try PresetBackupStore(directory: directory).save(data, protecting: legacy.lastPathComponent),
            legacy
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testCorruptHashNamedBackupIsNeverOverwrittenOrDeleted() throws {
        let directory = try temporary()
        let store = PresetBackupStore(directory: directory)
        let url = try store.save(Data("original".utf8), protecting: nil)
        let damaged = Data("damaged bytes to preserve".utf8)
        try damaged.write(to: url)
        XCTAssertThrowsError(try store.save(Data("original".utf8), protecting: nil))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testRetentionProtectsEveryRestoreLevelBeyondFiveRecentBackups() throws {
        let directory = try temporary()
        let store = PresetBackupStore(directory: directory)
        let first = try store.save(Data([0]), protecting: nil, now: Date(timeIntervalSince1970: 0))
        let second = try store.save(Data([1]), protecting: nil, now: Date(timeIntervalSince1970: 1))
        let pinned: Set<String> = [first.lastPathComponent, second.lastPathComponent]
        for value in 2 ... 12 {
            _ = try store.save(
                Data([UInt8(value)]),
                protecting: pinned,
                now: Date(timeIntervalSince1970: Double(value))
            )
        }
        XCTAssertEqual(try Data(contentsOf: first), Data([0]))
        XCTAssertEqual(try Data(contentsOf: second), Data([1]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count,
                       PresetBackupStore.recentCount + pinned.count)
    }
}
