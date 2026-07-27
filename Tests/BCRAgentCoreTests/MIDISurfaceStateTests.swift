import XCTest
@testable import BCRAgentCore

final class MIDISurfaceStateTests: XCTestCase {
    func testTracksHardwareInputAndSoftwareOutputSeparately() {
        var surface = MIDISurfaceState()
        let input = MIDIVoiceMessage.controlChange(channel: 0, number: 12, value: 31)
        let output = MIDIVoiceMessage.controlChange(channel: 0, number: 12, value: 127)

        surface.observe(input, direction: .input, at: Date(timeIntervalSince1970: 1))
        surface.observe(output, direction: .output, at: Date(timeIntervalSince1970: 2))

        let control = surface.controls[0]
        XCTAssertEqual(control.inputValue, 31)
        XCTAssertEqual(control.outputValue, 127)
        XCTAssertEqual(control.displayedValue, 127)
        XCTAssertEqual(control.lastDirection, .output)
        XCTAssertEqual(control.eventCount, 2)
    }

    func testNoteOffClearsDisplayedButtonValue() {
        var surface = MIDISurfaceState()
        surface.observe(
            .noteOn(channel: 1, number: 64, velocity: 100),
            direction: .input
        )
        surface.observe(
            .noteOff(channel: 1, number: 64, velocity: 45),
            direction: .input
        )

        XCTAssertEqual(surface.controls[0].inputValue, 0)
        XCTAssertEqual(surface.controls[0].displayedValue, 0)
    }

    func testControlsSortByKindChannelAndNumber() {
        var surface = MIDISurfaceState()
        surface.observe(
            .noteOn(channel: 0, number: 1, velocity: 1),
            direction: .input
        )
        surface.observe(
            .controlChange(channel: 2, number: 1, value: 1),
            direction: .input
        )
        surface.observe(
            .controlChange(channel: 0, number: 9, value: 1),
            direction: .input
        )

        XCTAssertEqual(
            surface.controls.map(\.id),
            [
                MIDIControlID(kind: .controlChange, channel: 0, number: 9),
                MIDIControlID(kind: .controlChange, channel: 2, number: 1),
                MIDIControlID(kind: .note, channel: 0, number: 1),
            ]
        )
    }
}
