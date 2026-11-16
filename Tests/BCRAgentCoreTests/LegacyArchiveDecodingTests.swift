import BCRFoundation
import BCRPersistenceAdapter
import BCRConfigurationAdapter
import Foundation
import XCTest

final class LegacyArchiveDecodingTests: XCTestCase {
    private func original() throws -> Data {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Persistence/agent-slot-v1.json")
        return try Data(contentsOf: path)
    }

    func testOldAgentArchiveKeepsEveryRequiredFieldAndDateRepresentation() throws {
        let data = try original()
        let value = try AgentSlotArchive.decode(data)
        XCTAssertEqual(value.id, AgentSlotID(2))
        XCTAssertEqual(value.name, "Custom name")
        XCTAssertEqual(value.state, .running)
        XCTAssertEqual(value.progress, 0.34)
        XCTAssertEqual(value.statusText, "Custom status")
        XCTAssertEqual(value.lastUpdated, Date(timeIntervalSinceReferenceDate: 1234))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: AgentSlotArchive.encode(value)),
                       try JSONDecoder().decode(JSONValue.self, from: data))
        XCTAssertEqual(
            try AgentSlotArchive.json([value]),
            .array([try JSONDecoder().decode(JSONValue.self, from: data)])
        )
    }

    func testOldRequiredUnknownFieldAndStrictSlotIDPoliciesRemain() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original()) as? [String: Any])
        for key in object.keys {
            var missing = object; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try AgentSlotArchive.decode(JSONSerialization.data(withJSONObject: missing)), key)
        }
        var extra = object; extra["future"] = "ignored"
        XCTAssertEqual(
            try AgentSlotArchive.decode(JSONSerialization.data(withJSONObject: extra)),
            try AgentSlotArchive.decode(original())
        )
        for id in [0, 9] {
            var invalid = object; invalid["id"] = ["rawValue": id]
            XCTAssertThrowsError(try AgentSlotArchive.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
    }
}
