import BCRFoundation
import BCRSurfaceDomain
import Foundation
import XCTest

@MainActor
final class MacroExecutionTests: XCTestCase {
    func testToggleShapeValidationRoundTripAndOldConfigurationReadability() async throws {
        let toggle: ParameterMutation = .toggle("gate")
        XCTAssertEqual(try JSONValue.encoded(toggle), .object(["toggle": .object(["_0": .string("gate")])]))
        XCTAssertEqual(try JSONDecoder().decode(ParameterMutation.self, from: JSONEncoder().encode(toggle)), toggle)
        let parameter = ParameterDefinition(id: "gate", name: "Gate", minimum: 0, maximum: 1, kind: .toggle)
        let macro = SurfaceMacro(id: "m", name: "Toggle", actions: [toggle])
        let configuration = SurfaceConfiguration(name: "test", parameters: [parameter], macros: [macro])
        try configuration.validate()
        var continuous = parameter; continuous.kind = .continuous
        XCTAssertThrowsError(try SurfaceConfiguration(name: "bad", parameters: [continuous], macros: [macro])
            .validate())
        var old = SurfaceConfiguration(
            name: "old",
            parameters: [parameter],
            macros: [.init(id: "old", name: "Set", actions: [.set("gate", 1)])]
        )
        old.version = 9
        XCTAssertEqual(try JSONDecoder().decode(SurfaceConfiguration.self, from: JSONEncoder().encode(old)), old)
    }

    func testRejectedStepsContinueAndReportReasonsWithoutEmittingForRejectedSteps() async {
        let configuration = SurfaceConfiguration(name: "test", parameters: [.init(id: "x", name: "X")], macros: [
            .init(
                id: "m",
                name: "Mixed",
                actions: [
                    .set("missing", 1),
                    .set("x", 20),
                    .toggle("x"),
                    .step("x", .infinity),
                    .resetGroup("missing"),
                    .step("x", 5)
                ]
            )
        ])
        var engine = SurfaceEngine(hardwareMap: .mockPreset(), configuration: configuration)
        let result = engine.runMacro("m", at: Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(result.steps.map(\.outcome), [.rejected, .applied, .rejected, .rejected, .rejected, .applied])
        XCTAssertEqual(result.steps[0].reason, .unknownParameter("missing"))
        XCTAssertEqual(result.steps[2].reason, .requiresToggle("x"))
        XCTAssertEqual(result.steps[3].reason, .invalidValue("x"))
        XCTAssertEqual(result.steps[4].reason, .unknownGroup("missing"))
        XCTAssertEqual(engine.value(of: "x"), 25)
        XCTAssertEqual(engine.lastMacroExecution, result)
    }

    func testMacroWithToggleIsOneUndoableBatchAndPhysicalButtonPublishesSameResults() async throws {
        let control = BCRControlID.button(row: 1, 1)
        let configuration = SurfaceConfiguration(name: "test", parameters: [
            .init(id: "gate", name: "Gate", minimum: 0, maximum: 1, kind: .toggle), .init(id: "x", name: "X")
        ], assignments: [.init(control: control, target: .runMacro("m"))], macros: [
            .init(id: "m", name: "Toggle", actions: [.toggle("gate"), .set("x", 50)])
        ])
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(), configuration: configuration,
                                     now: { Date(timeIntervalSinceReferenceDate: 100) },
                                     historyTime: .init(now: { 100 }),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        XCTAssertEqual(session.runMacro("m").steps.map(\.outcome), [.applied, .applied])
        XCTAssertEqual(session.engine.value(of: "gate"), 1)
        try session.undo()
        XCTAssertEqual(session.engine.value(of: "gate"), 0); XCTAssertEqual(session.engine.value(of: "x"), 0)
        XCTAssertFalse(session.canUndo)
        session.press(control)
        XCTAssertEqual(session.engine.lastMacroExecution?.steps.map(\.outcome), [.applied, .applied])
        XCTAssertEqual(session.engine.value(of: "gate"), 1)
    }
}
