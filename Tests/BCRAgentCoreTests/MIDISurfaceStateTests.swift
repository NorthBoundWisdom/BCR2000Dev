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

    func testControlsKeepFirstDiscoveryOrderWhenCCNumbersDiffer() {
        var surface = MIDISurfaceState()
        surface.observe(
            .controlChange(channel: 0, number: 57, value: 1),
            direction: .input
        )
        surface.observe(
            .controlChange(channel: 0, number: 58, value: 1),
            direction: .input
        )
        surface.observe(
            .controlChange(channel: 0, number: 81, value: 1),
            direction: .input
        )
        surface.observe(
            .controlChange(channel: 0, number: 55, value: 1),
            direction: .input
        )
        surface.observe(
            .controlChange(channel: 0, number: 55, value: 67),
            direction: .input
        )

        XCTAssertEqual(
            surface.controls.map(\.id),
            [
                MIDIControlID(kind: .controlChange, channel: 0, number: 57),
                MIDIControlID(kind: .controlChange, channel: 0, number: 58),
                MIDIControlID(kind: .controlChange, channel: 0, number: 81),
                MIDIControlID(kind: .controlChange, channel: 0, number: 55),
            ]
        )
        XCTAssertEqual(surface.controls[3].inputValue, 67)
    }

    func testFeedbackUpdatesTheExistingHardwareControl() {
        var surface = MIDISurfaceState()
        let control = MIDIControlID(kind: .controlChange, channel: 0, number: 55)

        surface.observe(
            .controlChange(channel: 0, number: 55, value: 40),
            direction: .input
        )
        surface.observe(
            MIDI1UMPCodec.feedback(control: control, value: 67),
            direction: .output
        )

        XCTAssertEqual(surface.controls.count, 1)
        XCTAssertEqual(surface.controls[0].id, control)
        XCTAssertEqual(surface.controls[0].inputValue, 40)
        XCTAssertEqual(surface.controls[0].outputValue, 67)
        XCTAssertEqual(surface.controls[0].displayedValue, 67)
    }
}
