import XCTest
@testable import BCRAgentConsole
@testable import BCRAgentCore

@MainActor
final class LEDDisplayTests: XCTestCase {
    func testDisplayShowsMovingControlValueThenUnknownPreset() async throws {
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false, initialPreset: .robotArm)
        let knob = BCRControlID.encoder(row: 1, 1)
        XCTAssertEqual(model.displayText, "----")
        model.turn(knob, by: 5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.displayedControl, knob)
        XCTAssertEqual(model.displayText, String(model.displayValue(of: knob)))
        // Buttons do not take over the display; only continuous controls do.
        model.press(.button(row: 1, 1)); model.release(.button(row: 1, 1))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.displayedControl, knob)
        try await Task.sleep(for: .milliseconds(1_600))
        XCTAssertNil(model.displayedControl)
        // The device never reports its preset, so nothing is guessed.
        XCTAssertEqual(model.displayText, "----")
    }

    func testSourceChangeClearsDisplayedValue() async throws {
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false, initialPreset: .robotArm)
        model.turn(.encoder(row: 1, 1), by: 5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(model.displayedControl)
        model.selectSource(.hardware)
        XCTAssertNil(model.displayedControl)
    }
}
