import BCRHTTPTransport
import Foundation
import XCTest

final class MultipleDisplayCredentialTests: XCTestCase {
    private func token(_ value: Int) -> String { String(repeating: String(value, radix: 16), count: 64) }
    private func object(extra: Int? = nil) -> [String: Any] {
        var value: [String: Any] = ["owner": token(1), "operator": token(2), "display": token(3)]
        if let extra { value["displays"] = (0 ..< extra).map { token($0 + 4) } }
        return value
    }

    private func data(_ object: [String: Any], paddedTo size: Int? = nil) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if let size { bytes.append(Data(repeating: 32, count: max(0, size - bytes.count))) }
        return bytes
    }

    func testOriginalThreeRolesRetainExact512ByteBoundary() throws {
        let legacy = try data(object(), paddedTo: 512)
        let clients = try SurfaceClientCredentials(data: legacy)
        XCTAssertFalse(clients.hasAdditionalDisplays)
        XCTAssertEqual(clients.displayCredentials.count, 1)
        XCTAssertThrowsError(try SurfaceClientCredentials(data: legacy + Data([32])))
    }

    func testEightDisplaysAccept2048BytesAndIssueDistinctOpaqueWriters() throws {
        let maximum = try data(object(extra: 7), paddedTo: 2048)
        let clients = try SurfaceClientCredentials(data: maximum)
        XCTAssertTrue(clients.hasAdditionalDisplays)
        XCTAssertEqual(clients.displayCredentials.count, 8)
        let writers = [clients.operatorWriterID] + clients.displayCredentials.map(\.writerID)
        XCTAssertEqual(Set(writers).count, 9)
        XCTAssertTrue(writers.allSatisfy { $0.count == 32 })
        XCTAssertThrowsError(try SurfaceClientCredentials(data: maximum + Data([32])))
    }

    func testMalformedExtraDisplaysAndEscapedDuplicateKeysFailClosed() throws {
        for mutation: (inout [String: Any]) -> Void in [
            { $0["displays"] = [] }, { $0["displays"] = (0 ..< 8).map { self.token($0 + 4) } },
            { $0["displays"] = "not-an-array" }, { $0["displays"] = [true] },
            { $0["displays"] = NSNull() }, { $0["displays"] = [self.token(1)] },
            { $0["displays"] = [self.token(2)] }, { $0["displays"] = [self.token(3)] },
            { $0["displays"] = [self.token(4), self.token(4)] }, { $0["displays"] = ["short"] },
            { $0["unknown"] = "no" }
        ] {
            var value = object(extra: 1)
            mutation(&value)
            XCTAssertThrowsError(try SurfaceClientCredentials(data: data(value)))
        }
        let valid = String(decoding: try data(object(extra: 1)), as: UTF8.self)
        for key in ["displays", #"displ\u0061ys"#] {
            let malformed = valid.dropLast() + ",\"\(key)\":[\"\(token(5))\"]}"
            XCTAssertThrowsError(try SurfaceClientCredentials(data: Data(malformed.utf8)))
        }
    }

    func testAllDisplayWritersExcludeLoadedPrincipalNamespaceWithoutChangingTokens() throws {
        var clients = try SurfaceClientCredentials(data: data(object(extra: 7)))
        let tokens = clients.displayCredentials.map(\.token)
        let excluded = Set([clients.operatorWriterID] + clients.displayCredentials.map(\.writerID))
        clients.excludeWriterIDs(excluded)
        let writers = Set([clients.operatorWriterID] + clients.displayCredentials.map(\.writerID))
        XCTAssertTrue(writers.isDisjoint(with: excluded))
        XCTAssertEqual(writers.count, 9)
        XCTAssertEqual(clients.displayCredentials.map(\.token), tokens)
    }
}
