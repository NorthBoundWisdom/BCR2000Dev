import BCRFoundation
import BCRMCPAdapter
import BCRProviderApplication
import BCRProviderMCPAdapter
import BCRSurfaceDomain
import Foundation
import SurfaceControlContracts
import XCTest

/// R4 regressions for the optional surface control adapter (P1-B).
@MainActor
final class SurfaceControlRegressionTests: XCTestCase {
    final class Clock { var time: Double = 10 }

    func host(provider: Bool = false, clock: Clock = Clock(),
              legacy: MCPPermissions = .init(deviceControl: true, simulationControl: true)) throws
        -> (MCPApplicationGateway, BCRSurfaceControlAdapter?)
    {
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: session, permissions: legacy, includeAgent: false)
        if provider {
            try ProviderMCPModule.install(on: gateway, application: ProviderApplication(configuration: .init()),
                                          enableSurfaceControl: true, surfaceInstanceID: "fixture",
                                          surfacePermissions: .init(input: true, feedback: true, reset: true))
            return (gateway, nil)
        }
        let adapter = try SurfaceControlMCPModule.install(
            on: gateway, instanceID: "fixture", permissions: .init(input: true, feedback: true, reset: true),
            monotonic: { clock.time }
        )
        return (gateway, try XCTUnwrap(adapter))
    }

    func call(_ gateway: MCPApplicationGateway, _ name: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        let result = gateway.call("surface_control_" + name, arguments: .object(args))
        XCTAssertFalse(result.isError, "\(name): \(result.value)")
        return result.value
    }

    func code(_ gateway: MCPApplicationGateway, _ name: String, _ args: [String: JSONValue]) -> JSONValue? {
        let result = gateway.call("surface_control_" + name, arguments: .object(args))
        XCTAssertTrue(result.isError, name)
        return result.value.objectValue?["code"]
    }

    func discovery(_ gateway: MCPApplicationGateway) throws -> [String: JSONValue] {
        try XCTUnwrap(call(gateway, "discover").objectValue)
    }

    func inputArgs(_ gateway: MCPApplicationGateway, _ control: String, _ value: JSONValue,
                   encoding: String = "scalar") throws -> [String: JSONValue]
    {
        let current = try discovery(gateway)
        return ["expected": current["expected"]!, "expected_sequence": current["latest_sequence"]!,
                "control_id": .string(control), "encoding": .string(encoding), "value": value]
    }

    func feedbackArgs(_ gateway: MCPApplicationGateway, _ control: String, kind: String,
                      _ value: JSONValue) throws -> [String: JSONValue]
    {
        let current = try discovery(gateway)
        return ["expected": current["expected"]!, "expected_sequence": current["latest_sequence"]!,
                "control_id": .string(control), "kind": .string(kind), "value": value]
    }

    // MARK: R4-01

    func testLegacyMockInputIsDeniedWhileSurfaceControlIsEnabled() throws {
        let (gateway, _) = try host(provider: true)
        let before = try discovery(gateway)
        let legacyBefore = gateway.session.inputEvents.snapshot()
        let args: JSONValue = .object([
            "operation": .string("turn"), "control": try .encoded(BCRControlID.pushEncoder(group: 1, 1)),
            "delta": .number(64)
        ])
        let result = gateway.call("console_mock_input", arguments: args)
        XCTAssertTrue(result.isError)
        let error = result.value.objectValue?["error"]?.objectValue
        XCTAssertEqual(error?["code"], .string("permission_denied"))
        XCTAssertTrue(error?["message"]?.stringValue?.contains("surface_control_input") == true)
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 0)
        XCTAssertEqual(gateway.session.inputEvents.snapshot(), legacyBefore)
        let after = try discovery(gateway)
        XCTAssertEqual(after["expected"], before["expected"])
        XCTAssertEqual(after["latest_sequence"], .string("0"))
        // The new path remains available with its own fences.
        let accepted = try call(gateway, "input", inputArgs(gateway, "pushEncoder.1.1", .number(64)))
        XCTAssertEqual(accepted.objectValue?["disposition"], .string("accepted"))
    }

    func testLegacyMockInputUnchangedWithoutSurfaceControl() throws {
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: session, permissions: .init(deviceControl: true),
                                            includeAgent: false)
        try ProviderMCPModule.install(on: gateway, application: ProviderApplication(configuration: .init()))
        XCTAssertFalse(gateway.toolDefinitions.contains { $0.objectValue?["name"] == .string("surface_control_input") })
        let result = gateway.call("console_mock_input", arguments: .object([
            "operation": .string("turn"), "control": try .encoded(BCRControlID.pushEncoder(group: 1, 1)),
            "delta": .number(64)
        ]))
        XCTAssertFalse(result.isError, "\(result.value)")
        XCTAssertEqual(result.value.objectValue?["origin"], .string("agent"))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 64)
    }

    func testUnexpectedAgentInputRevokesContextInsteadOfRecordingRemoteInput() throws {
        let (gateway, adapter) = try host()
        let before = try discovery(gateway)
        gateway.session.withWriteOrigin(.agent) { gateway.session.turn(.pushEncoder(group: 1, 1), by: 50) }
        XCTAssertEqual(adapter?.diagnosticCount, 1)
        XCTAssertEqual(adapter?.diagnostics.last?.reason, "unexpected_input_origin_agent")
        let after = try discovery(gateway)
        XCTAssertNotEqual(after["expected"], before["expected"])
        XCTAssertEqual(after["latest_sequence"], .string("0"))
        let snapshot = try call(gateway, "snapshot", ["instance_id": .string("fixture")]).objectValue!
        XCTAssertEqual(snapshot["inputs"]?.objectValue?["pushEncoder.1.1"], .number(50)) // reseeded, no event
        let page = try call(gateway, "events", ["instance_id": .string("fixture"),
                                                "epoch": after["expected"]!.objectValue!["epoch"]!,
                                                "after_sequence": .string("0"), "limit": .number(16)])
        XCTAssertEqual(page.objectValue?["events"], .array([]))
        XCTAssertTrue(gateway.audit.contains { $0.method == "surface_control.context" && !$0.succeeded })
        // Ordinary local interface input is still journaled as interface.
        gateway.session.turn(.pushEncoder(group: 1, 2), by: 5)
        let local = try call(gateway, "events", ["instance_id": .string("fixture"),
                                                 "epoch": after["expected"]!.objectValue!["epoch"]!,
                                                 "after_sequence": .string("0"), "limit": .number(16)])
        XCTAssertEqual(local.objectValue?["events"]?.arrayValue?.first?.objectValue?["origin"], .string("interface"))
    }

    // MARK: R4-02

    func testFeedbackOverlayDoesNotSwallowEqualAbsoluteInput() throws {
        let (gateway, _) = try host()
        _ = try call(gateway, "feedback", feedbackArgs(gateway, "pushEncoder.1.1", kind: "value", .number(80)))
        XCTAssertEqual(gateway.session.mock.value(of: .pushEncoder(group: 1, 1)), 80) // display unchanged behavior
        let result = try call(gateway, "input", inputArgs(gateway, "pushEncoder.1.1", .number(80)))
        XCTAssertEqual(result.objectValue?["disposition"], .string("accepted"))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 80)
        XCTAssertEqual(gateway.session.mock.inputDataValues[.pushEncoder(group: 1, 1)], 80)
    }

    func testFeedbackOverlayDoesNotSwallowEqualNRPNInput() throws {
        let (gateway, _) = try host()
        try gateway.session.setMockNRPN(true, for: .pushEncoder(group: 1, 1))
        _ = try call(gateway, "feedback", feedbackArgs(gateway, "pushEncoder.1.1", kind: "value", .number(16383)))
        XCTAssertEqual(gateway.session.mock.rawValues[.pushEncoder(group: 1, 1)], 16383)
        let result = try call(gateway, "input", inputArgs(gateway, "pushEncoder.1.1", .number(16383)))
        XCTAssertEqual(result.objectValue?["disposition"], .string("accepted"))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 127)
        XCTAssertEqual(gateway.session.mock.inputDataValues[.pushEncoder(group: 1, 1)], 16383)
    }

    func testAbsoluteInputAfterFeedbackUsesRequestedPositionNotDisplay() throws {
        let (gateway, _) = try host()
        _ = try call(gateway, "input", inputArgs(gateway, "pushEncoder.1.1", .number(20)))
        _ = try call(gateway, "feedback", feedbackArgs(gateway, "pushEncoder.1.1", kind: "value", .number(100)))
        let result = try call(gateway, "input", inputArgs(gateway, "pushEncoder.1.1", .number(60)))
        XCTAssertEqual(result.objectValue?["disposition"], .string("accepted"))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 60)
    }

    // MARK: R4-13

    func testObservationFailureRecoversWithFreshEpoch() throws {
        let clock = Clock()
        let (gateway, adapter) = try host(clock: clock)
        let before = try discovery(gateway)
        clock.time = 5 // regressed clock: recording the observed GUI input fails
        gateway.session.turn(.pushEncoder(group: 1, 1), by: 30)
        XCTAssertEqual(adapter?.diagnostics.last, .init(reason: "observation_failed", code: "invalid_time"))
        XCTAssertEqual(code(gateway, "discover", [:]), .string("invalid_time")) // still fail closed
        clock.time = 20
        let after = try discovery(gateway) // no admin reset needed
        XCTAssertNotEqual(after["expected"], before["expected"])
        let snapshot = try call(gateway, "snapshot", ["instance_id": .string("fixture")]).objectValue!
        XCTAssertEqual(snapshot["inputs"]?.objectValue?["pushEncoder.1.1"], .number(30))
        let next = try call(gateway, "input", inputArgs(gateway, "pushEncoder.1.1", .number(90)))
        XCTAssertEqual(next.objectValue?["disposition"], .string("accepted"))
    }

    // MARK: R4-14

    func testEveryMappingChangePathRotatesEpochAndOrdinaryWritesDoNot() throws {
        let paths: [(String, (SurfaceSession) throws -> Void)] = [
            ("replaceConfiguration", { try $0.replaceConfiguration($0.engine.configuration, persist: false) }),
            ("addParameter", { try $0.addParameter(.init(id: "extra", name: "Extra", minimum: 0, maximum: 127)) }),
            ("updateParameter", { session in
                var definition = try XCTUnwrap(session.engine.configuration.parameter("simulation.arm"))
                definition.maximum = 100; try session.updateParameter(definition)
            }),
            ("removeParameter", { $0.removeParameter("simulation.progress") }),
            ("setAssignment", { try $0.setAssignment(nil, for: .pushEncoder(group: 1, 2)) }),
            ("bulkAssignment", { session in
                var configuration = session.engine.configuration
                try configuration.addParameter(.init(id: "bulk.1", name: "B", group: "bulk", minimum: 0, maximum: 1))
                try session.replaceConfiguration(configuration, persist: false)
                let plan = try BulkAssignmentPlan(configuration: session.engine.configuration, section: .pushEncoder,
                                                  row: 2, group: "bulk")
                try session.applyBulkAssignment(plan)
            }),
            ("selectPage", { session in
                var configuration = session.engine.configuration
                try configuration.addPage(.init(id: "p2", name: "P2", assignments: []))
                try session.updatePrograms(configuration)
                try session.selectPage("p2")
            }),
            ("mockNRPN", { try $0.setMockNRPN(true, for: .pushEncoder(group: 1, 3)) }),
            ("installHardwareMap", { try $0.installHardwareMap(.mockPreset()) }),
            ("sourceRoundTrip", { $0.selectSource(.hardware); $0.selectSource(.mock) })
        ]
        for (name, change) in paths {
            let (gateway, _) = try host()
            let revision = gateway.session.mappingContextRevision
            let before = try discovery(gateway)
            try change(gateway.session)
            XCTAssertNotEqual(gateway.session.mappingContextRevision, revision, name)
            XCTAssertNotEqual(try discovery(gateway)["expected"], before["expected"], name)
        }
        let (gateway, _) = try host()
        let revision = gateway.session.mappingContextRevision
        let before = try discovery(gateway)
        gateway.session.setParameter("simulation.start", to: 40)
        gateway.session.turn(.pushEncoder(group: 1, 1), by: 3)
        _ = try call(gateway, "input", inputArgs(gateway, "pushEncoder.1.2", .number(9)))
        _ = try call(gateway, "feedback", feedbackArgs(gateway, "pushEncoder.1.5", kind: "value", .number(12)))
        XCTAssertEqual(gateway.session.mappingContextRevision, revision)
        XCTAssertEqual(try discovery(gateway)["expected"], before["expected"])
    }

    // MARK: R4-15 / R4-18

    func testFailedValidationLeavesEngineJournalAndBudgetUntouched() throws {
        let clock = Clock()
        let (gateway, _) = try host(clock: clock)
        gateway.permissions.writesPerSecond = 1
        var args = try inputArgs(gateway, "pushEncoder.1.1", .number(100))
        clock.time = 1 // regressed: validation fails before the engine and the budget
        XCTAssertEqual(code(gateway, "input", args), .string("invalid_time"))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 0)
        clock.time = 11
        args["value"] = .number(128)
        XCTAssertEqual(code(gateway, "input", args), .string("invalid_value"))
        args["value"] = .number(100)
        let accepted = try call(gateway, "input", args) // the single write is still available
        XCTAssertEqual(accepted.objectValue?["sequence"], .string("1"))
        XCTAssertEqual(code(gateway, "feedback", try feedbackArgs(gateway, "pushEncoder.1.5", kind: "value",
                                                                  .number(1))), .string("rate_limited"))
        XCTAssertEqual(try discovery(gateway)["latest_sequence"], .string("1"))
    }

    func testResetCommitsSessionThenCoreAndHostErrorsKeepTheirCode() throws {
        let (gateway, _) = try host()
        _ = try call(gateway, "input", inputArgs(gateway, "pushEncoder.1.1", .number(100)))
        _ = try call(gateway, "feedback", feedbackArgs(gateway, "pushEncoder.1.5", kind: "value", .number(90)))
        let current = try discovery(gateway)
        let reset = try call(gateway, "reset", ["expected": current["expected"]!,
                                                "expected_sequence": current["latest_sequence"]!])
        XCTAssertEqual(reset.objectValue?["latest_sequence"], .string("0"))
        XCTAssertEqual(gateway.session.mock.value(of: .pushEncoder(group: 1, 5)), 0)
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 0)
        XCTAssertEqual(BCRSurfaceControlAdapter.failureCode(ProviderDomainError("unsupported", "x")), "unsupported")
        XCTAssertEqual(BCRSurfaceControlAdapter.failureCode(ControlContractError("stale_epoch")), "stale_epoch")
        XCTAssertEqual(BCRSurfaceControlAdapter.failureCode(MCPToolFailure("x")), "invalid_argument")
    }

    // MARK: R4-16

    func testButtonsDeclareOnlyIndicatorFeedback() throws {
        let (gateway, _) = try host()
        let profile = try discovery(gateway)["profile"]!.objectValue!["controls"]!.arrayValue!
        let buttons = profile.filter { $0.objectValue?["input_kind"] == .string("button") }
        XCTAssertFalse(buttons.isEmpty)
        XCTAssertTrue(buttons.allSatisfy { $0.objectValue?["feedback_kinds"] == .array([.string("indicator")]) })
        XCTAssertEqual(code(gateway, "feedback", try feedbackArgs(gateway, "button.1.1", kind: "value", .bool(true))),
                       .string("unsupported_feedback"))
        _ = try call(gateway, "feedback", feedbackArgs(gateway, "button.1.1", kind: "indicator", .string("on")))
        XCTAssertEqual(gateway.session.mock.value(of: .button(row: 1, 1)), 127)
    }
}
