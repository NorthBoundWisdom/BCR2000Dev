import XCTest
@testable import BCRAgentCore
@testable import BCRMCPAdapter
@testable import BCRSurfaceDomain

final class HardwareMapTests: XCTestCase {
    func testLayoutHas108UniquePhysicalControlsInPanelOrder() {
        let all = BCRLayout.allControls
        XCTAssertEqual(all.count, 32 + 32 + 16 + 24 + 4)
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(all, all.sorted())
        XCTAssertEqual(all.first, .pushEncoder(group: 1, 1))
        XCTAssertEqual(all.last, .userButton(4))
        XCTAssertEqual(BCRLayout.control(after: .encoder(row: 1, 8)), .encoder(row: 2, 1))
        XCTAssertNil(BCRLayout.control(after: .encoder(row: 3, 8)))
    }

    func testControlIDDecodingRejectsPositionsOutsideTheLayout() {
        let invalid = Data(#"{"section":"button","row":3,"index":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BCRControlID.self, from: invalid))
    }

    func testMockPresetBindsEveryControlToADistinctCC() {
        let preset = HardwareMap.mockPreset()
        XCTAssertEqual(preset.boundCount, BCRLayout.allControls.count)
        XCTAssertEqual(Set(preset.entries.map(\.midi)).count, preset.boundCount)
        XCTAssertEqual(preset.midi(for: .pushEncoder(group: 1, 1)), cc(1))
        XCTAssertEqual(preset.control(for: cc(65)), .button(row: 1, 1))
        XCTAssertEqual(preset.control(for: cc(108)), .userButton(4))
    }

    func testBindRejectsMIDIAlreadyOwnedByAnotherControl() {
        var map = HardwareMap()
        XCTAssertNoThrow(try map.bind(.encoder(row: 1, 1), to: cc(10)))
        XCTAssertThrowsError(try map.bind(.encoder(row: 1, 2), to: cc(10))) { error in
            XCTAssertEqual(error as? HardwareBindingError, .alreadyBound(cc(10), to: .encoder(row: 1, 1)))
        }
    }

    func testRebindingTheSameControlReplacesItsIdentity() throws {
        var map = HardwareMap()
        try map.bind(.button(row: 1, 1), to: cc(10))
        try map.bind(.button(row: 1, 1), to: MIDIControlID(kind: .note, channel: 0, number: 60))
        XCTAssertEqual(map.boundCount, 1)
        XCTAssertNil(map.control(for: cc(10)))
    }

    func testEncodersCannotLearnNotes() {
        var map = HardwareMap()
        let note = MIDIControlID(kind: .note, channel: 0, number: 60)
        XCTAssertThrowsError(try map.bind(.encoder(row: 1, 1), to: note)) { error in
            XCTAssertEqual(error as? HardwareBindingError, .encoderRequiresControlChange(.encoder(row: 1, 1)))
        }
    }

    func testMapCodableRoundTrip() throws {
        let map = HardwareMap.mockPreset()
        let decoded = try JSONDecoder().decode(HardwareMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded, map)
    }
}

func cc(_ number: UInt8, channel: UInt8 = 0) -> MIDIControlID {
    MIDIControlID(kind: .controlChange, channel: channel, number: number)
}
