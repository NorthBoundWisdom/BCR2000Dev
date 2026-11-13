import BCRTestSupport
import BCRAgentCore
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

    func testMapArchivesArePrivateAndBoundedWithoutTouchingUnknownFiles() throws {
        let directory = try temporary()
        let store = PresetMapArchiveStore(directory: directory)
        let unrelated = directory.appending(path: "my-map.json")
        try Data("private".utf8).write(to: unrelated)
        let corrupt = directory.appending(path: "hardware-map-before-restore-\(UUID().uuidString).json")
        try Data("broken".utf8).write(to: corrupt)
        let link = directory.appending(path: "hardware-map-before-restore-\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        var archives: [URL] = []
        for index in 0 ..< 9 {
            archives.append(try store.save(HardwareMap(), now: Date(timeIntervalSince1970: Double(index))))
        }
        for file in archives.prefix(4) { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        for file in archives.suffix(5) {
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int,
                0o600
            )
        }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("private".utf8))
        XCTAssertEqual(try Data(contentsOf: corrupt), Data("broken".utf8))
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testNestedRestoreHistoryIsFlattenedAndLimitedToFiveLevels() throws {
        var point = PresetRestorePoint(backupFile: "0.syx", hardwareMap: HardwareMap(), createdAt: .now)
        for index in 1 ... 20 {
            point = PresetRestorePoint(backupFile: "\(index).syx", hardwareMap: HardwareMap(), createdAt: .now,
                                       expectedPreset: Data(repeating: 0, count: 30000), history: [point])
        }
        point = point.bounded()
        XCTAssertEqual(point.history?.map(\.backupFile), ["16.syx", "17.syx", "18.syx", "19.syx"])
        XCTAssertTrue(point.history?.allSatisfy { $0.history == nil } == true)
        XCTAssertEqual(point.protectedFiles.count, PresetRestorePoint.maximumLevels)
        XCTAssertEqual(point.bounded(), point)
        XCTAssertLessThan(try JSONEncoder().encode(point).count, 250000)
    }

    @MainActor
    func testLoadingOldNestedHistoryRewritesABoundedFlatRecord() throws {
        let directory = try temporary()
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let store = JSONFileStore<PresetRestorePoint>(fileURL: directory
            .appending(path: "preset-alignment-restore.json"))
        var point = PresetRestorePoint(backupFile: "0.syx", hardwareMap: HardwareMap(), createdAt: .now)
        for index in 1 ... 8 {
            point = PresetRestorePoint(backupFile: "\(index).syx", hardwareMap: HardwareMap(), createdAt: .now,
                                       history: [point])
        }
        try store.save(point)
        let model = ConsoleViewModel(stores: stores, startsMIDI: false)
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved, model.presetRestorePoint)
        XCTAssertEqual(saved.history?.map(\.backupFile), ["4.syx", "5.syx", "6.syx", "7.syx"])
        XCTAssertTrue(saved.history?.allSatisfy { $0.history == nil } == true)
    }
}
