import BCRTestSupport
import XCTest
@testable import BCRAgentCore

final class PresetDocumentSafetyTests: XCTestCase {
    private func preset(buttons: [String] = []) -> Data {
        BCLFixtures.dump(["$rev R1", "$preset", ".name 'Safe'", ".egroups 4", ".lock off"]
            + BCLFixtures.encoderSections() + buttons + ["$end"])
    }

    func testDuplicateButtonAddressPrefersLearnedOwnerIndependentOfBlockOrder() throws {
        let address = MIDIControlID(kind: .controlChange, channel: 15, number: 90)
        var map = try BCLFixtures.encoderMap()
        let learned = BCRControlID.pushEncoderButton(group: 1, 2)
        try map.bind(learned, to: address)
        let one = ["$button 1", ".easypar CC 16 90 127 0 toggleoff"]
        let two = ["$button 2", ".easypar CC 16 90 127 0 toggleoff"]
        let a = try BCRPresetAlignment.prepare(dump: preset(buttons: one + two), hardwareMap: map,
                                               configuration: .neutral())
        for index in 0 ..< 20 {
            let buttons = index.isMultiple(of: 2) ? one + two : two + one
            let b = try BCRPresetAlignment.prepare(dump: preset(buttons: buttons), hardwareMap: map,
                                                   configuration: .neutral())
            XCTAssertEqual(b.hardwareMap, a.hardwareMap)
            XCTAssertEqual(b.hardwareMap.midi(for: learned), address)
        }
    }

    func testUnlearnedDuplicateUsesAscendingButtonNumber() throws {
        let a = ["$button 2", ".easypar CC 16 90 127 0 toggleoff", "$button 1", ".easypar CC 16 90 127 0 toggleoff"]
        let plan = try BCRPresetAlignment.prepare(dump: preset(buttons: a), hardwareMap: BCLFixtures.encoderMap(),
                                                  configuration: .neutral())
        let first = try XCTUnwrap(plan.lines.firstIndex(of: "$button 1"))
        XCTAssertEqual(plan.lines[first + 1], ".easypar CC 16 90 127 0 toggleoff")
        XCTAssertNotEqual(plan.hardwareMap.midi(for: .pushEncoderButton(group: 1, 2)),
                          .init(kind: .controlChange, channel: 15, number: 90))
    }

    func testNewButtonAddressesReserveAllProgrammingKeyDefinitions() throws {
        let extra = (53 ... 64).flatMap { ["$button \($0)", ".easypar CC 16 \($0 - 53) 127 0 toggleoff"] }
        let plan = try BCRPresetAlignment.prepare(dump: preset(buttons: extra), hardwareMap: BCLFixtures.encoderMap(),
                                                  configuration: .neutral())
        let reserved = Set((0 ..< 12).map { MIDIControlID(kind: .controlChange, channel: 15, number: UInt8($0)) })
        let allocated = Set(plan.hardwareMap.entries.filter { !$0.control.isContinuous }.map(\.midi))
        XCTAssertEqual(allocated.count, 52)
        XCTAssertTrue(allocated.isDisjoint(with: reserved))
    }

    func testFullReadbackComparisonRejectsUnrelatedEditsAndDefaultChanges() throws {
        let expected = ["$rev R1", "$preset", ".name 'Safe'", ".egroups 4", ".request off",
                        "$encoder 1", ".easypar CC 1 1 0 127 absolute", ".default 0", "$end"]
        XCTAssertTrue(try BCRPresetAlignment.readbackMatches(BCLFixtures.dump(expected), expected: expected))
        for replacement in [expected.map { $0 == ".request off" ? ".request on" : $0 },
                            expected.map { $0 == ".default 0" ? ".default 1" : $0 }]
        {
            XCTAssertFalse(try BCRPresetAlignment.readbackMatches(BCLFixtures.dump(replacement), expected: expected))
        }
        let moved = expected.map { $0 == ".default 0" ? ".default 1" : $0 }
        XCTAssertEqual(try BCRPresetAlignment.identityLines(of: BCLFixtures.dump(moved)),
                       try BCRPresetAlignment.identityLines(of: BCLFixtures.dump(expected)))
    }

    func testReadbackAllowsOnlyNumberedBlockReordering() throws {
        let header = ["$rev R1", "$preset", ".egroups 4"]
        let one = ["$button 1", ".easypar CC 16 1 127 0 toggleoff"]
        let two = ["$button 2", ".easypar CC 16 2 127 0 toggleoff"]
        XCTAssertTrue(try BCRPresetAlignment.readbackMatches(BCLFixtures.dump(header + one + two + ["$end"]),
                                                             expected: header + two + one + ["$end"]))
        XCTAssertThrowsError(try BCRPresetAlignment.canonicalLines(header + one + one + ["$end"]))
    }
}
