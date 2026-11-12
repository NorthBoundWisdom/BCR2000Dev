import BCRProviderMCPAdapter
import Darwin
import Foundation
import XCTest

final class SurfaceControlPrincipalsTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testExplicitRecordIsPrivateStableAndContainsNoCredential() throws {
        let url = try directory().appending(path: "principal.json")
        let first = try SurfaceControlPrincipals.loadOrCreate(at: url)
        XCTAssertEqual(first, try SurfaceControlPrincipals.loadOrCreate(at: url))
        XCTAssertNotEqual(first, SurfaceControlPrincipals())
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["schema_version", "remote_writer_id", "interface_writer_id", "system_writer_id"]
        )
        XCTAssertEqual(Set([first.remoteWriterID, first.interfaceWriterID, first.systemWriterID]).count, 3)
        var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("credential"))
    }

    func testUnsafeFilesAndInvalidRecordsFailWithoutReplacement() throws {
        let root = try directory()
        let original = root.appending(path: "original.json")
        _ = try SurfaceControlPrincipals.loadOrCreate(at: original)
        let bytes = try Data(contentsOf: original)
        let link = root.appending(path: "symlink.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try SurfaceControlPrincipals.loadOrCreate(at: link))
        let directory = root.appending(path: "directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try SurfaceControlPrincipals.loadOrCreate(at: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: original.path)
        XCTAssertThrowsError(try SurfaceControlPrincipals.loadOrCreate(at: original))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for mutation: (inout [String: Any]) -> Void in [
            { $0["unknown"] = true }, { $0["schema_version"] = true }, { $0["schema_version"] = 2 },
            { $0["remote_writer_id"] = "short" }, { $0["interface_writer_id"] = $0["remote_writer_id"] },
            { $0.removeValue(forKey: "system_writer_id") },
            { $0["system_writer_id"] = String(repeating: "X", count: 32) }
        ] {
            var object = base; mutation(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: original)
            XCTAssertThrowsError(try SurfaceControlPrincipals.loadOrCreate(at: original))
            XCTAssertEqual(try Data(contentsOf: original), data)
        }
        let valid = String(decoding: bytes, as: UTF8.self)
        for malformed in [
            valid.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":1.0"),
            valid.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":1e0"),
            valid.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":1,\"schema_version\":1"),
            valid.replacingOccurrences(
                of: "\"schema_version\":1",
                with: "\"schema_version\":1,\"schema_\\u0076ersion\":1"
            )
        ] {
            XCTAssertNotEqual(malformed, valid)
            let data = Data(malformed.utf8)
            try data.write(to: original)
            XCTAssertThrowsError(try SurfaceControlPrincipals.loadOrCreate(at: original))
            XCTAssertEqual(try Data(contentsOf: original), data)
        }
        let fifo = root.appending(path: "fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try SurfaceControlPrincipals.loadOrCreate(at: fifo))
    }
}
