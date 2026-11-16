import BCRFoundation
import BCRSurfaceDomain
import BCRExamples
import BCRPersistenceAdapter
import Foundation
import XCTest
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class LocalDataFileTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testFinalBrokenAndParentLinksAreRejectedForReadWriteAndEvidence() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        let bytes = Data("original".utf8)
        try bytes.write(to: target)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let broken = root.appendingPathComponent("broken.json")
        try FileManager.default.createSymbolicLink(
            at: broken,
            withDestinationURL: root.appendingPathComponent("absent")
        )
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: real)
        let brokenParent = root.appendingPathComponent("broken-parent")
        try FileManager.default.createSymbolicLink(
            at: brokenParent,
            withDestinationURL: root.appendingPathComponent("missing-dir")
        )
        for url in [link, broken, parent.appendingPathComponent("child"),
                    brokenParent.appendingPathComponent("child")]
        {
            XCTAssertThrowsError(try LocalDataFile.read(url, maximumBytes: 100))
            XCTAssertThrowsError(try LocalDataFile.replace(Data("new".utf8), at: url, maximumBytes: 100) { _ in })
            XCTAssertThrowsError(try CaptureEvidenceFile(url: url))
        }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testBoundedRegularReadRejectsOversizeDirectoriesAndFIFO() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data(repeating: 7, count: 101).write(to: file)
        XCTAssertThrowsError(try LocalDataFile.read(file, maximumBytes: 100)) {
            XCTAssertEqual($0 as? LocalDataFileError, .tooLarge)
        }
        XCTAssertThrowsError(try LocalDataFile.read(root, maximumBytes: 100))
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)), 0)
        XCTAssertThrowsError(try LocalDataFile.read(fifo, maximumBytes: 100)) {
            XCTAssertEqual($0 as? LocalDataFileError, .notRegularFile)
        }
    }

    func testExclusiveCreationAndContentBackupVerifyExactBytesAndNeverOverwriteConflicts() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        let bytes = Data("unmodified source".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try CaptureEvidenceFile(url: file))
        let backup = try LocalDataFile.contentBackup(bytes, original: file, kind: "backup", maximumBytes: 100)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertEqual(
            try LocalDataFile.contentBackup(bytes, original: file, kind: "backup", maximumBytes: 100),
            backup
        )
        let conflict = Data("conflict".utf8)
        try conflict.write(to: backup)
        XCTAssertThrowsError(try LocalDataFile.contentBackup(bytes, original: file, kind: "backup", maximumBytes: 100))
        XCTAssertEqual(try Data(contentsOf: backup), conflict)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: file)
        XCTAssertThrowsError(try LocalDataFile.contentBackup(bytes, original: file, kind: "backup", maximumBytes: 100))
        XCTAssertTrue(try backup.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertThrowsError(try LocalDataFile.contentBackup(
            Data("wrong source".utf8),
            original: file,
            kind: "other",
            maximumBytes: 100
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }

    func testAtomicStoreUsesBoundedReadsAndPreservesChangedOrOversizeOriginal() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileStore<[String]>(fileURL: root.appendingPathComponent("data.json"))
        try store.save(["old"])
        let before = try XCTUnwrap(store.readEncoded())
        XCTAssertThrowsError(try store.writeEncoded(Data("[]".utf8), expectedOriginal: Data(), requireUnchanged: true))
        XCTAssertEqual(try store.readEncoded(), before)
        try Data(repeating: 32, count: JSONFileStore<[String]>.maximumBytes + 1).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(["new"]))
        XCTAssertEqual(try store.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       JSONFileStore<[String]>.maximumBytes + 1)
    }

    func testFutureConfigurationRefusedBeforeDecodeAndNeverReplacedByLaterSave() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileStore<SurfaceConfiguration>(fileURL: root.appendingPathComponent("future.json"))
        let future = Data("{\"version\":\(SurfaceConfiguration.currentVersion + 1),\"newAction\":{\"unknown\":true}}"
            .utf8)
        try future.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? LocalDataFileError, .newerVersion(SurfaceConfiguration.currentVersion + 1))
        }
        let file = ProtectedJSONFile.configuration(store)
        let loaded = file.load()
        XCTAssertTrue(loaded.failed)
        XCTAssertTrue(loaded.message?.contains(String(SurfaceConfiguration.currentVersion + 1)) == true)
        XCTAssertThrowsError(try file.save(loaded.value))
        XCTAssertThrowsError(try store.save(.starter()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["future.json"])
    }

    func testFutureHardwareMapUsesItsOwnVersionAndRemainsProtected() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileStore<HardwareMap>(fileURL: root.appendingPathComponent("hardware.json"))
        let future = Data("{\"version\":\(HardwareMap.currentVersion + 1),\"unknownFutureMapping\":true}".utf8)
        try future.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        let file = ProtectedJSONFile.hardware(store)
        XCTAssertTrue(file.load().failed)
        XCTAssertThrowsError(try file.save(HardwareMap()))
        XCTAssertThrowsError(try store.save(HardwareMap()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["hardware.json"])
    }

    func testBadBackupBytesCannotPermitProtectedSave() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONFileStore<SurfaceConfiguration>(fileURL: root.appendingPathComponent("corrupt.json"))
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: store.fileURL)
        let file = ProtectedJSONFile(store: store, title: "Test", normalize: { try $0.migrated() },
                                     version: { $0.version }, fallback: { .starter() },
                                     writeBackup: { _, url in try Data("wrong backup".utf8).write(to: url) })
        XCTAssertTrue(file.load().failed)
        XCTAssertThrowsError(try file.save(.starter()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }
}
