import BCRFoundation
import Foundation
import XCTest
@testable import BCRAgentConsole

final class LegacyOutputArchiveTests: XCTestCase {
    private let raw = Data(#"{"version":1,"enabled":false,"host":"127.0.0.1","port":9000,"enableParameter":"enabled","ledSource":"target","limits":[{"id":"x","minimum":-1,"maximum":1,"maximumChange":0.2,"maximumVelocity":0.3}]}"#
        .utf8)
    func testOldOutputSettingsWithoutTransportDecodeIntoActualSharedLimits() throws {
        let settings = try JSONDecoder().decode(OutputSettings.self, from: raw)
        XCTAssertEqual(settings.transport, .osc)
        XCTAssertEqual(settings.version, 1)
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.enableParameter, "enabled")
        let value = try XCTUnwrap(settings.limits.first)
        XCTAssertEqual(value.id, "x")
        XCTAssertEqual(value.minimum, -1)
        XCTAssertEqual(value.maximum, 1)
        XCTAssertEqual(value.maximumChange, 0.2)
        XCTAssertEqual(value.maximumVelocity, 0.3)
        let saved = try JSONDecoder().decode(OutputSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved, settings)
    }

    func testOldLimitRequiredKeysAndUnknownFieldPolicyRemainUnchanged() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let limits = try XCTUnwrap(root["limits"] as? [[String: Any]])
        let original = try XCTUnwrap(limits.first)
        for key in original.keys {
            var value = original; value.removeValue(forKey: key)
            var body = root; body["limits"] = [value]
            XCTAssertThrowsError(
                try JSONDecoder().decode(OutputSettings.self, from: JSONSerialization.data(withJSONObject: body)),
                key
            )
        }
        var extra = original; extra["future"] = "ignored"
        var body = root; body["limits"] = [extra]
        XCTAssertEqual(
            try JSONDecoder().decode(OutputSettings.self, from: JSONSerialization.data(withJSONObject: body)),
            try JSONDecoder().decode(OutputSettings.self, from: raw)
        )
        // Legacy Codable reading was structural; semantic limit validation remains at explicit apply/start.
        var invalid = original; invalid["minimum"] = 3
        body["limits"] = [invalid]
        XCTAssertEqual(
            try JSONDecoder().decode(OutputSettings.self, from: JSONSerialization.data(withJSONObject: body)).limits
                .first?.minimum,
            3
        )
    }
}
