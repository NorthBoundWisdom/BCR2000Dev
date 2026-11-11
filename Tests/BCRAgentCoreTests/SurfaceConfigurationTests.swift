import XCTest
@testable import BCRAgentCore

final class SurfaceConfigurationTests: XCTestCase {
    private let joint = ParameterDefinition(id: "j", name: "Joint", unit: "°", minimum: -90, maximum: 90)

    func testContinuousParameterMapsSevenBitValuesAcrossItsRange() {
        XCTAssertEqual(joint.value(fromMIDI: 0), -90)
        XCTAssertEqual(joint.value(fromMIDI: 127), 90)
        XCTAssertEqual(joint.midiValue(for: 0), 64)
        for midi in UInt8(0) ... 127 {
            XCTAssertEqual(joint.midiValue(for: joint.value(fromMIDI: midi)), midi)
        }
        XCTAssertEqual(joint.clamp(400), 90)
    }

    func testToggleParameterSnapsToItsEnds() {
        let toggle = ParameterDefinition(id: "t", name: "T", minimum: 0, maximum: 1, kind: .toggle)
        XCTAssertEqual(toggle.value(fromMIDI: 63), 0)
        XCTAssertEqual(toggle.value(fromMIDI: 64), 1)
        XCTAssertEqual(toggle.clamp(0.7), 1)
        XCTAssertEqual(toggle.midiValue(for: 1), 127)
    }

    func testValidationRejectsEmptyNameAndInvertedRange() {
        XCTAssertThrowsError(try ParameterDefinition(id: "x", name: " ").validate())
        XCTAssertThrowsError(try ParameterDefinition(id: "x", name: "X", minimum: 5, maximum: 5).validate()) { error in
            XCTAssertEqual(error as? ParameterDefinitionError, .invalidRange(minimum: 5, maximum: 5))
        }
    }

    func testTriggersCannotBeAssignedToEncoders() {
        var configuration = SurfaceConfiguration(name: "t")
        let assignment = ControlAssignment(control: .encoder(row: 1, 1), target: .agentPrimaryAction(AgentSlotID(1)))
        XCTAssertThrowsError(try configuration.assign(assignment)) { error in
            XCTAssertEqual(error as? ControlAssignmentError, .triggerRequiresButton(.encoder(row: 1, 1)))
        }
    }

    func testAssignmentToUnknownParameterIsRejected() {
        var configuration = SurfaceConfiguration(name: "t")
        let assignment = ControlAssignment(control: .encoder(row: 1, 1), target: .parameter("missing"))
        XCTAssertThrowsError(try configuration.assign(assignment))
    }

    func testRemovingAParameterClearsItsAssignments() throws {
        var configuration = SurfaceConfiguration(name: "t", parameters: [joint])
        try configuration.assign(ControlAssignment(control: .encoder(row: 1, 1), target: .parameter("j")))
        try configuration.assign(ControlAssignment(control: .pushEncoder(group: 2, 1), target: .parameter("j")))
        configuration.removeParameter("j")
        XCTAssertTrue(configuration.assignments.isEmpty)
    }

    func testRobotArmDemoIsInternallyConsistentAndCodable() throws {
        let demo = SurfaceConfiguration.robotArmDemo()
        for parameter in demo.parameters {
            XCTAssertNoThrow(try parameter.validate())
        }
        for assignment in demo.assignments {
            if case let .parameter(id) = assignment.target {
                XCTAssertNotNil(demo.parameter(id), "\(id)")
            }
        }
        XCTAssertEqual(demo.assignment(for: .pushEncoder(group: 1, 1))?.target, .parameter("arm.j1"))
        let decoded = try JSONDecoder().decode(SurfaceConfiguration.self, from: JSONEncoder().encode(demo))
        XCTAssertEqual(decoded, demo)
    }

    func testMakeParameterIDSkipsExistingIDs() throws {
        var configuration = SurfaceConfiguration(name: "t")
        try configuration.addParameter(ParameterDefinition(id: "custom.1", name: "A"))
        XCTAssertEqual(configuration.makeParameterID(), "custom.2")
        XCTAssertThrowsError(try configuration.addParameter(ParameterDefinition(id: "custom.1", name: "B")))
    }
}

final class ConfigurationPresetCoreTests: XCTestCase {
    func testStarterIsValidNeutralAndRoundTrips() throws {
        let starter = SurfaceConfiguration.starter()
        XCTAssertEqual(starter.name, "默认配置")
        XCTAssertEqual(starter.parameters.map(\.id.rawValue), (1 ... 8).map { "general.\($0)" })
        XCTAssertTrue(starter.parameters.allSatisfy { $0.kind == .continuous && $0.group == "通用" })
        XCTAssertFalse(starter.parameters.contains { $0.id.rawValue.hasPrefix("arm.") })
        for index in 1 ... 8 {
            XCTAssertEqual(starter.controls(targetingParameter: ParameterID("general.\(index)")),
                           [.pushEncoder(group: 1, index)])
            XCTAssertEqual(starter.controls(targeting: .agentPrimaryAction(AgentSlotID(index))),
                           [.button(row: 1, index)])
        }
        XCTAssertEqual(starter.controls(targeting: .resetGroup("通用")), [.button(row: 2, 8)])

        let decoded = try JSONDecoder().decode(SurfaceConfiguration.self, from: JSONEncoder().encode(starter))
        XCTAssertEqual(try decoded.migrated(), starter)
    }

    func testEveryPresetBuildsItsNamedConfiguration() {
        XCTAssertEqual(ConfigurationPreset.allCases, [.starter, .robotArm])
        for preset in ConfigurationPreset.allCases {
            XCTAssertEqual(preset.makeConfiguration().name, preset.title)
            XCTAssertFalse(preset.summary.isEmpty)
        }
        XCTAssertEqual(ConfigurationPreset.robotArm.makeConfiguration(), .robotArmDemo())
    }
}
