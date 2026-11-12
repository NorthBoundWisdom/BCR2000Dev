import XCTest
@testable import BCRAgentCore

final class LEDRingTests: XCTestCase {
    func testObservedHardwareBoundaries() {
        XCTAssertEqual(LEDRingMode.twoDot.litLEDs(value: 2), [0])
        XCTAssertEqual(LEDRingMode.twoDot.litLEDs(value: 3), [0, 1])
        XCTAssertEqual(LEDRingMode.twoDot.litLEDs(value: 7), [1])
        XCTAssertEqual(LEDRingMode.twoDot.litLEDs(value: 12), [1, 2])
        XCTAssertEqual(LEDRingMode.oneDot.litLEDs(value: 4), [0])
        XCTAssertEqual(LEDRingMode.oneDot.litLEDs(value: 5), [1])
    }

    func testEndpointsAndAllValuesKeepAtLeastOneLEDInObservedModes() {
        for mode in [LEDRingMode.oneDot, .twoDot] {
            XCTAssertEqual(mode.litLEDs(value: 0), [0])
            XCTAssertEqual(mode.litLEDs(value: 127), [14])
            for value in UInt8(0) ... 127 {
                let leds = mode.litLEDs(value: value)!
                XCTAssertFalse(leds.isEmpty)
                XCTAssertTrue(leds.allSatisfy { (0 ..< 15).contains($0) })
                XCTAssertLessThanOrEqual(leds.count, mode == .oneDot ? 1 : 2)
            }
        }
    }

    func testMockUsesItsExplicitRingProfileAndFeedback() throws {
        var mock = MockBCR2000()
        let control = BCRControlID.pushEncoder(group: 4, 1)
        let midi = try XCTUnwrap(mock.preset.midi(for: control))
        mock.receive(MIDI1UMPCodec.feedback(control: midi, value: 3))
        XCTAssertEqual(mock.ringLEDs(of: control), [0, 1])
        XCTAssertEqual(mock.ringLEDs(of: .encoder(row: 1, 1)), [0])
    }

    func testV4MapRetainsBindingsWithoutInventingRingMode() throws {
        let old = HardwareMap(version: 4, entries: [.init(control: .encoder(row: 1, 1),
                                                          midi: .init(kind: .controlChange, channel: 0, number: 1))])
        let decoded = try JSONDecoder().decode(HardwareMap.self, from: JSONEncoder().encode(old)).migrated()
        XCTAssertEqual(decoded.version, 5)
        XCTAssertEqual(decoded.entries, old.entries)
        XCTAssertNil(decoded.ringMode(for: .encoder(row: 1, 1)))
    }

    func testLearnedModeRoundTripsAndRelearningAnotherIdentityClearsIt() throws {
        let control = BCRControlID.encoder(row: 1, 1)
        let midi = MIDIControlID(kind: .controlChange, channel: 0, number: 1)
        var map = HardwareMap()
        try map.bind(control, to: midi, ringMode: .oneDot)
        let decoded = try JSONDecoder().decode(HardwareMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded.ringMode(for: control), .oneDot)
        try map.bind(control, to: midi)
        XCTAssertEqual(map.ringMode(for: control), .oneDot)
        try map.bind(control, to: .init(kind: .controlChange, channel: 0, number: 2))
        XCTAssertNil(map.ringMode(for: control))
        XCTAssertNil(LEDRingMode.pan.litLEDs(value: 64))
        XCTAssertEqual(LEDRingMode.oneDotOff.litLEDs(value: 0), [])
        XCTAssertEqual(LEDRingMode.twoDotOff.litLEDs(value: 0), [])
    }
}
