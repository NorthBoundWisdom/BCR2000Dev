import XCTest
@testable import BCRAgentCore

final class MockBCR2000Tests: XCTestCase {
    func testTurningSendsAbsoluteCCAndClampsAtLimits() {
        var device = MockBCR2000()
        let encoder = BCRControlID.encoder(row: 1, 1)

        XCTAssertNil(device.turn(encoder, by: -1), "Already at 0")
        XCTAssertEqual(device.turn(encoder, by: 200), .controlChange(channel: 0, number: 81, value: 127))
        XCTAssertNil(device.turn(encoder, by: 1))
        XCTAssertEqual(device.sentCount, 1)
    }

    func testButtonsSendMomentaryPressAndRelease() {
        var device = MockBCR2000()
        XCTAssertEqual(device.press(.button(row: 1, 1)), .controlChange(channel: 0, number: 65, value: 127))
        XCTAssertEqual(device.release(.button(row: 1, 1)), .controlChange(channel: 0, number: 65, value: 0))
        XCTAssertNil(device.press(.encoder(row: 1, 1)))
    }

    func testFeedbackMovesTheInternalValueLikeU1Mode() {
        var device = MockBCR2000()
        let encoder = BCRControlID.pushEncoder(group: 2, 1)

        XCTAssertEqual(device.receive(.controlChange(channel: 0, number: 9, value: 100)), encoder)
        XCTAssertEqual(device.value(of: encoder), 100)
        // Turning continues from the software-written position.
        XCTAssertEqual(device.turn(encoder, by: 1), .controlChange(channel: 0, number: 9, value: 101))
        XCTAssertNil(device.receive(.controlChange(channel: 9, number: 9, value: 1)))
    }

    func testActiveGroupIsClamped() {
        var device = MockBCR2000()
        device.activeGroup = 9
        XCTAssertEqual(device.activeGroup, 4)
    }

    /// Full loop: mock knob → engine → parameter → feedback → mock LED ring, and back.
    func testMockAndEngineStayInSyncInBothDirections() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        var device = MockBCR2000()
        var engine = SurfaceEngine(hardwareMap: device.preset, configuration: .robotArmDemo())
        func deliver(_ effects: [SurfaceEffect]) {
            for case let .send(message) in effects {
                device.receive(message)
            }
        }
        deliver(engine.fullFeedback(at: now))
        let j1 = BCRControlID.pushEncoder(group: 1, 1)
        XCTAssertEqual(device.value(of: j1), 64, "J1 default 0° sits mid-ring")

        // Hardware → software
        let message = device.turn(j1, by: 63)!
        deliver(engine.handleInput(message, at: now.addingTimeInterval(1)))
        XCTAssertEqual(engine.value(of: "arm.j1"), 180)

        // Software → hardware
        deliver(engine.setParameter("arm.j1", to: -180, at: now.addingTimeInterval(2)))
        XCTAssertEqual(device.value(of: j1), 0)

        // Toggle button LED is owned by software
        let enable = BCRControlID.button(row: 2, 1)
        deliver(engine.handleInput(device.press(enable)!, at: now.addingTimeInterval(3)))
        deliver(engine.handleInput(device.release(enable)!, at: now.addingTimeInterval(3.1)))
        XCTAssertEqual(engine.value(of: "arm.enabled"), 1)
        XCTAssertEqual(device.value(of: enable), 127)
    }
}
