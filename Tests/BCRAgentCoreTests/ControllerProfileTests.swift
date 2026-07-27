import XCTest
@testable import BCRAgentCore

final class ControllerProfileTests: XCTestCase {
    func testQuickLearnBindsEightDistinctControlsInSlotOrder() {
        var profile = ControllerProfile()

        for index in 0..<8 {
            let control = MIDIControlID(
                kind: .controlChange,
                channel: 0,
                number: UInt8(32 + index)
            )
            let binding = profile.learn(control)
            XCTAssertEqual(binding?.slotID, AgentSlotID(index + 1))
        }

        XCTAssertTrue(profile.isComplete)
        XCTAssertNil(profile.nextUnboundSlot)
    }

    func testQuickLearnRejectsDuplicateControl() {
        var profile = ControllerProfile()
        let control = MIDIControlID(kind: .note, channel: 0, number: 42)

        XCTAssertNotNil(profile.learn(control))
        XCTAssertNil(profile.learn(control))
        XCTAssertEqual(profile.bindings.count, 1)
    }

    func testProfileCodableRoundTrip() throws {
        var profile = ControllerProfile()
        _ = profile.learn(
            MIDIControlID(kind: .controlChange, channel: 1, number: 7)
        )

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ControllerProfile.self, from: encoded)

        XCTAssertEqual(decoded, profile)
    }
}
