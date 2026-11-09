import Foundation
import XCTest
@testable import BCRAgentCore

final class PersistenceValidationTests: XCTestCase {
    func testAgentSlotDecoderRejectsOutOfRangeInsteadOfBypassingInitializer() throws {
        for value in [0, 9, -1] {
            XCTAssertThrowsError(try JSONDecoder().decode(AgentSlotID.self, from: Data("{\"rawValue\":\(value)}".utf8))) {
                XCTAssertTrue($0 is DecodingError)
            }
        }
        XCTAssertEqual(try JSONDecoder().decode(AgentSlotID.self, from: Data("{\"rawValue\":8}".utf8)), AgentSlotID(8))
    }

    func testMIDIDecoderRejectsInvalidChannelsAndNumbers() throws {
        for (channel, number) in [(16, 1), (0, 128), (-1, 1), (0, -1)] {
            let json = "{\"kind\":\"controlChange\",\"channel\":\(channel),\"number\":\(number)}"
            XCTAssertThrowsError(try JSONDecoder().decode(MIDIControlID.self, from: Data(json.utf8))) {
                XCTAssertTrue($0 is DecodingError)
            }
        }
    }
    func testNullNonOptionalDefinitionFieldsAreNotSilentlyDefaulted() throws {
        let definition = try JSONValue.encoded(ParameterDefinition(id: "x", name: "X")).objectValue!
        for field in ["group", "unit", "minimum", "maximum", "defaultValue", "kind", "agentWritable"] {
            var raw = definition
            raw[field] = .null
            XCTAssertThrowsError(try JSONValue.object(raw).decoded(ParameterDefinition.self))
        }
    }

    private func codes(_ configuration: SurfaceConfiguration) -> [SurfaceValidationIssue.Code] {
        do { try configuration.validate(); XCTFail("Expected invalid configuration"); return [] }
        catch let error as SurfaceValidationError { return error.issues.map(\.code) }
        catch { XCTFail("Unexpected error: \(error)"); return [] }
    }

    func testWholeConfigurationReportsMultipleConcreteIssues() {
        let parameter = ParameterDefinition(id: "j", name: "Joint")
        let control = BCRControlID.encoder(row: 1, 1)
        let configuration = SurfaceConfiguration(version: 999, name: "", parameters: [parameter, parameter], assignments: [
            ControlAssignment(control: control, target: .parameter("missing")),
            ControlAssignment(control: control, target: .agentPrimaryAction(AgentSlotID(1))),
        ])
        let actual = codes(configuration)
        for expected in [SurfaceValidationIssue.Code.unsupportedVersion, .emptyName, .duplicateParameter,
                         .duplicateAssignment, .unknownParameter, .encoderTrigger] {
            XCTAssertTrue(actual.contains(expected), "Missing \(expected)")
        }
    }

    func testEveryInvalidParameterRuleIsRejected() {
        let invalid: [ParameterDefinition] = [
            .init(id: "", name: "Name"),
            .init(id: "x", name: "\n"),
            .init(id: "x", name: "Name", minimum: 1, maximum: 1),
            .init(id: "x", name: "Name", minimum: 2, maximum: 1),
            .init(id: "x", name: "Name", minimum: -.infinity),
            .init(id: "x", name: "Name", maximum: .nan),
            .init(id: "x", name: "Name", minimum: -1e308, maximum: 1e308),
            .init(id: "x", name: "Name", defaultValue: .nan),
            .init(id: "x", name: "Name", defaultValue: 999),
        ]
        for definition in invalid {
            XCTAssertTrue(codes(SurfaceConfiguration(name: "Test", parameters: [definition])).contains(.invalidParameter))
        }
    }

    func testLargeFiniteRangeHasFiniteMidpoint() throws {
        let definition = ParameterDefinition(id: "x", name: "Large", minimum: 1e308, maximum: 1.5e308)
        try definition.validate()
        XCTAssertTrue(definition.midpoint.isFinite)
        XCTAssertEqual(definition.normalized(definition.midpoint), 0.5, accuracy: 1e-12)
    }

    func testUnknownResetGroupIsRejectedAndAssignmentFailureIsAtomic() {
        var configuration = SurfaceConfiguration(name: "Test")
        let original = configuration
        XCTAssertThrowsError(try configuration.assign(ControlAssignment(control: .userButton(1), target: .resetGroup("missing"))))
        XCTAssertEqual(configuration, original)
        XCTAssertTrue(codes(SurfaceConfiguration(name: "Test", assignments: [
            ControlAssignment(control: .userButton(1), target: .resetGroup("missing")),
        ])).contains(.unknownGroup))
    }

    func testDecodedDuplicateParametersAndInvalidAgentSlotsAreRejected() throws {
        let parameter = ParameterDefinition(id: "x", name: "X")
        let duplicates = SurfaceConfiguration(name: "Test", parameters: [parameter, parameter])
        XCTAssertThrowsError(try JSONValue.encoded(duplicates).decoded(SurfaceConfiguration.self))
        var raw = try JSONValue.encoded(SurfaceConfiguration.robotArmDemo()).objectValue!
        var assignments = raw["assignments"]!.arrayValue!
        let index = try XCTUnwrap(assignments.firstIndex { $0.objectValue?["target"]?.objectValue?["agentPrimaryAction"] != nil })
        var assignment = assignments[index].objectValue!
        assignment["target"] = .object(["agentPrimaryAction": .object(["_0": .object(["rawValue": .number(99)])])])
        assignments[index] = .object(assignment); raw["assignments"] = .array(assignments)
        XCTAssertThrowsError(try JSONValue.object(raw).decoded(SurfaceConfiguration.self)) { XCTAssertTrue($0 is DecodingError) }
    }

    func testHardwareMapValidationRejectsDuplicateBindingsAndEncoderNotes() throws {
        let a = BCRControlID.encoder(row: 1, 1), b = BCRControlID.encoder(row: 1, 2)
        let cc = MIDIControlID(kind: .controlChange, channel: 0, number: 1)
        for map in [
            HardwareMap(entries: [.init(control: a, midi: cc), .init(control: a, midi: cc)]),
            HardwareMap(entries: [.init(control: a, midi: cc), .init(control: b, midi: cc)]),
            HardwareMap(entries: [.init(control: a, midi: .init(kind: .note, channel: 0, number: 1))]),
            HardwareMap(version: 999),
        ] {
            XCTAssertThrowsError(try map.validate())
            XCTAssertThrowsError(try JSONValue.encoded(map).decoded(HardwareMap.self))
        }
        try HardwareMap.mockPreset().validate()
    }

    func testRemovingLastGroupParameterClearsDanglingResetAction() throws {
        var configuration = SurfaceConfiguration(name: "Test", parameters: [
            ParameterDefinition(id: "x", name: "X", group: "group"),
        ], assignments: [.init(control: .userButton(1), target: .resetGroup("group"))])
        configuration.removeParameter("x")
        XCTAssertTrue(configuration.assignments.isEmpty)
        try configuration.validate()
    }

    func testConfigurationReplacementStopsLearningWithVisibleEventAndRejectsInvalidState() async throws {
        try await MainActor.run {
            let session = SurfaceSession(hardwareDevice: ValidationFakeDevice(), saveHardwareMap: { _ in }, saveConfiguration: { _ in })
            session.selectSource(.hardware)
            let control = BCRControlID.encoder(row: 1, 1)
            session.beginLearning(at: control)
            var events: [SurfaceSessionEvent] = []
            session.onEvent = { events.append($0) }
            XCTAssertThrowsError(try session.replaceConfiguration(SurfaceConfiguration(name: "")))
            XCTAssertEqual(session.engine.learnTarget, control)
            XCTAssertTrue(events.isEmpty)
            XCTAssertNoThrow(try session.replaceConfiguration(.robotArmDemo()))
            XCTAssertNil(session.engine.learnTarget)
            XCTAssertTrue(events.contains(.learningInterruptedByConfiguration(control)))
        }
    }
}
@MainActor
private final class ValidationFakeDevice: SurfaceDevice {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func send(_ message: MIDIVoiceMessage) throws {}
}

