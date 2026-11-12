import XCTest
@testable import BCRAgentCore

final class ButtonPreviewTests: XCTestCase {
    private func dump(_ lines: [String]) -> Data {
        Data(lines.enumerated().flatMap { i, line in
            [0xF0, 0, 0x20, 0x32, 0, 0x15, 0x20, UInt8(i >> 7), UInt8(i & 127)] + Array(line.utf8) + [0xF7]
        })
    }

    func testLearnsButtonIdentitiesForPreviewWithoutAssigningOrExecutingActions() throws {
        let lines = ["$rev R1", "$preset", ".egroups 4", "$button 1", ".easypar CC 16 100 127 0 toggleoff",
                     "$button 33", ".easypar CC 16 101 127 0 increment 1", "$button 49",
                     ".easypar NOTE 16 60 127 0 toggleoff",
                     "$end"]
        let plan = try BCRPresetButtonLearning.prepare(dump: dump(lines), existingMap: HardwareMap())
        XCTAssertEqual(plan.hardwareMap.boundCount, 3)
        XCTAssertEqual(plan.unconfigured.count, 49)
        XCTAssertTrue(plan.unsupported.isEmpty)
        let button = BCRControlID.button(row: 1, 1)
        XCTAssertTrue(plan.hardwareMap.isVisualizationOnly(button))
        XCTAssertNotNil(plan.hardwareMap.midi(for: .userButton(1)))
        var engine = SurfaceEngine(hardwareMap: plan.hardwareMap, configuration: .robotArmDemo())
        XCTAssertTrue(engine.handleInput(.controlChange(channel: 15, number: 101, value: 1)).isEmpty)
        XCTAssertTrue(engine.fullFeedback().isEmpty)
        let decoded = try JSONDecoder().decode(HardwareMap.self, from: JSONEncoder().encode(plan.hardwareMap))
        XCTAssertEqual(decoded, plan.hardwareMap)
    }

    func testExistingFunctionalBindingRemainsFunctionalAndConflictingIdentityIsRejected() throws {
        let lines = ["$rev R1", "$preset", ".egroups 4", "$button 33", ".easypar CC 16 101 127 0 increment 1", "$end"]
        var map = HardwareMap()
        try map.bind(.button(row: 1, 1), to: .init(kind: .controlChange, channel: 15, number: 101))
        let plan = try BCRPresetButtonLearning.prepare(dump: dump(lines), existingMap: map)
        XCTAssertFalse(plan.hardwareMap.isVisualizationOnly(.button(row: 1, 1)))
        try map.bind(.button(row: 1, 1), to: .init(kind: .controlChange, channel: 15, number: 102))
        XCTAssertThrowsError(try BCRPresetButtonLearning.prepare(dump: dump(lines), existingMap: map))
        XCTAssertThrowsError(try map.bind(
            .encoder(row: 1, 1),
            to: .init(kind: .controlChange, channel: 0, number: 1),
            visualizationOnly: true
        ))
    }

    func testSharedEncoderIdentityIsReportedInsteadOfGuessingButtonActivity() throws {
        var map = HardwareMap()
        try map.bind(.encoder(row: 3, 6), to: .init(kind: .controlChange, channel: 0, number: 102))
        let lines = ["$rev R1", "$preset", ".egroups 4", "$button 6", ".easypar CC 1 102 127 0 increment 1", "$end"]
        let plan = try BCRPresetButtonLearning.prepare(dump: dump(lines), existingMap: map)
        XCTAssertEqual(plan.unsupported, [.pushEncoderButton(group: 1, 6)])
        XCTAssertEqual(plan.hardwareMap.entries, map.entries)
    }

    func testPreviewKeepsSoftwareIndicatorStateWithoutHardwareFeedback() throws {
        var map = HardwareMap()
        let button = BCRControlID.button(row: 2, 1)
        try map.bind(button, to: .init(kind: .controlChange, channel: 15, number: 90), visualizationOnly: true)
        var engine = SurfaceEngine(hardwareMap: map, configuration: .robotArmDemo())
        XCTAssertTrue(engine.setParameter("arm.enabled", to: 1).isEmpty)
        XCTAssertEqual(engine.state(of: button).value, 127)
        XCTAssertTrue(engine.handleInput(.controlChange(channel: 15, number: 90, value: 0)).isEmpty)
        XCTAssertEqual(engine.value(of: "arm.enabled"), 1)
    }
}
