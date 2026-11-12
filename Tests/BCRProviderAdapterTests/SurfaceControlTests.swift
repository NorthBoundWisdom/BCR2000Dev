import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import BCRProviderMCPAdapter
import Foundation
import XCTest

@MainActor
final class SurfaceControlTests: XCTestCase {
    func fixture(allow: Bool = true, capacity: Int = 1024) throws -> (MCPApplicationGateway, BCRSurfaceControlAdapter) {
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(
            session: session,
            permissions: .init(deviceControl: true, simulationControl: true),
            includeAgent: false
        )
        let adapter = try SurfaceControlMCPModule.install(
            on: gateway,
            instanceID: "fixture",
            permissions: .init(input: allow, feedback: allow, reset: allow),
            eventCapacity: capacity
        )
        return (gateway, try XCTUnwrap(adapter))
    }

    func call(_ gateway: MCPApplicationGateway, _ name: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        let result = gateway.call("surface_control_" + name, arguments: .object(args))
        XCTAssertFalse(result.isError, "\(name): \(result.value)")
        return result.value
    }

    func write(_ gateway: MCPApplicationGateway, value: JSONValue,
               control: String = "pushEncoder.1.1") throws -> JSONValue
    {
        let discovery = try call(gateway, "discover").objectValue!
        return try call(
            gateway,
            "input",
            ["expected": discovery["expected"]!, "expected_sequence": discovery["latest_sequence"]!,
             "control_id": .string(control), "encoding": .string("scalar"),
             "value": value]
        )
    }

    func testDiscoverSeedAndRawMockInputUseStableIDsAndSeparateInventory() throws {
        let (gateway, _) = try fixture()
        let discovery = try call(gateway, "discover")
        XCTAssertEqual(discovery.objectValue?["source"], .string("simulation"))
        XCTAssertEqual(discovery.objectValue?["latest_sequence"], .string("0"))
        let initial = try call(gateway, "snapshot", ["instance_id": .string("fixture")])
        XCTAssertEqual(initial.objectValue?["inputs"]?.objectValue?["pushEncoder.1.1"], .number(0))
        let result = try write(gateway, value: .number(100))
        XCTAssertEqual(result.objectValue?["disposition"], .string("accepted"))
        XCTAssertEqual(result.objectValue?["origin"], .string("remote"))
        XCTAssertEqual(result.objectValue?["source"], .string("simulation"))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 100)
        let old = try gateway.session.inputEvents.read(generation: nil)
        XCTAssertTrue(old.objectValue?["events"]?.arrayValue?
            .contains { $0.objectValue?["source"] == .string("mock") } == true)
        let off = try write(gateway, value: .number(0))
        XCTAssertEqual(off.objectValue?["disposition"], .string("accepted"))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 0)
    }

    func testRepeatedCASAndInvalidRequestsCannotPartiallyCommit() throws {
        let (gateway, _) = try fixture()
        let discovery = try call(gateway, "discover").objectValue!
        var args: [String: JSONValue] = ["expected": discovery["expected"]!, "expected_sequence": .string("0"),
                                         "control_id": .string("pushEncoder.1.1"), "encoding": .string("scalar"),
                                         "value": .number(90)]
        _ = try call(gateway, "input", args)
        let before = try call(gateway, "snapshot", ["instance_id": .string("fixture")]).objectValue!
        let duplicate = gateway.call("surface_control_input", arguments: .object(args))
        XCTAssertTrue(duplicate.isError)
        XCTAssertEqual(duplicate.value.objectValue?["code"], .string("stale_sequence"))
        args["expected_sequence"] = .string("1"); args["encoding"] = .string("midi")
        XCTAssertTrue(gateway.call("surface_control_input", arguments: .object(args)).isError)
        args["encoding"] = .string("scalar"); args["value"] = .number(128)
        XCTAssertTrue(gateway.call("surface_control_input", arguments: .object(args)).isError)
        let after = try call(gateway, "snapshot", ["instance_id": .string("fixture")]).objectValue!
        XCTAssertEqual(before["inputs"], after["inputs"])
        XCTAssertEqual(before["latest_sequence"], after["latest_sequence"])
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 90)
    }

    func testSameValueConsumesSequenceAsIgnoredAndDoesNotRenewInput() throws {
        let (gateway, _) = try fixture()
        _ = try write(gateway, value: .number(100))
        let repeatInput = try write(gateway, value: .number(100))
        XCTAssertEqual(repeatInput.objectValue?["disposition"], .string("ignored"))
        XCTAssertEqual(repeatInput.objectValue?["reason"], .string("no_change"))
        XCTAssertEqual(repeatInput.objectValue?["sequence"], .string("2"))
    }

    func testDisplayFeedbackCannotChangeInputParameterOrTriggerActionAndClearsBeforeHardware() throws {
        let (gateway, _) = try fixture()
        var triggers = 0
        gateway.session.onTriggerAgent = { _ in triggers += 1 }
        let discovery = try call(gateway, "discover").objectValue!
        let oldSequence = gateway.session.inputEvents.sequence
        _ = try call(gateway, "feedback", ["expected": discovery["expected"]!, "expected_sequence": .string("0"),
                                           "control_id": .string("button.1.1"), "kind": .string("indicator"),
                                           "value": .string("blink")])
        XCTAssertEqual(gateway.session.mock.value(of: .button(row: 1, 1)), 96)
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.state"), 0)
        XCTAssertEqual(triggers, 0)
        let snapshot = try call(gateway, "snapshot", ["instance_id": .string("fixture")]).objectValue!
        XCTAssertEqual(snapshot["inputs"]?.objectValue?["button.1.1"], .bool(false))
        XCTAssertEqual(snapshot["feedback"]?.objectValue?["button.1.1"]?.objectValue?["indicator"], .string("blink"))
        let legacy = try gateway.session.inputEvents.read(
            generation: gateway.session.inputEvents.generation,
            after: oldSequence
        )
        XCTAssertFalse(legacy.objectValue?["events"]?.arrayValue?
            .contains { $0.objectValue?["kind"] == .string("control.input") } == true)
        gateway.session.selectSource(.hardware)
        XCTAssertEqual(gateway.session.engine.state(of: .button(row: 1, 1)).value, 0)
        XCTAssertTrue(gateway.call("surface_control_input", arguments: .object([:])).isError)
    }

    func testDefaultPermissionsProtectedParameterAndContextChangesFailClosed() throws {
        let (gateway, _) = try fixture(allow: false)
        let discovery = try call(gateway, "discover").objectValue!
        let args: [String: JSONValue] = ["expected": discovery["expected"]!, "expected_sequence": .string("0"),
                                         "control_id": .string("pushEncoder.1.1"), "encoding": .string("scalar"),
                                         "value": .number(100)]
        XCTAssertEqual(
            gateway.call("surface_control_input", arguments: .object(args)).value.objectValue?["code"],
            .string("permission_denied")
        )
        let (writable, _) = try fixture()
        let old = try call(writable, "discover").objectValue!
        var definition = try XCTUnwrap(writable.session.engine.configuration.parameter("simulation.arm"))
        definition.externallyProtected = true
        try writable.session.updateParameter(definition)
        var stale = args; stale["expected"] = old["expected"]
        XCTAssertEqual(
            writable.call("surface_control_input", arguments: .object(stale)).value.objectValue?["code"],
            .string("stale_epoch")
        )
        let current = try call(writable, "discover").objectValue!
        stale["expected"] = current["expected"]
        XCTAssertEqual(
            writable.call("surface_control_input", arguments: .object(stale)).value.objectValue?["code"],
            .string("permission_denied")
        )
        XCTAssertEqual(writable.session.engine.value(of: "simulation.arm"), 0)
    }

    func testGUIInputAndResetKeepRawInputSeparateFromFeedback() throws {
        let (gateway, _) = try fixture()
        gateway.session.turn(.pushEncoder(group: 1, 1), by: 70)
        let discovery = try call(gateway, "discover").objectValue!
        XCTAssertEqual(discovery["latest_sequence"], .string("1"))
        let snapshot = try call(gateway, "snapshot", ["instance_id": .string("fixture")])
        XCTAssertEqual(snapshot.objectValue?["inputs"]?.objectValue?["pushEncoder.1.1"], .number(70))
        let reset = try call(
            gateway,
            "reset",
            ["expected": discovery["expected"]!, "expected_sequence": discovery["latest_sequence"]!]
        )
        XCTAssertNotEqual(reset.objectValue?["expected"], discovery["expected"])
        XCTAssertEqual(reset.objectValue?["latest_sequence"], .string("0"))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.arm"), 0)
        let after = try call(gateway, "snapshot", ["instance_id": .string("fixture")])
        XCTAssertEqual(after.objectValue?["inputs"]?.objectValue?["pushEncoder.1.1"], .number(0))
    }

    func testDisplayOverlayIsRevokedOnPageAssignmentProgramsAndEncodingChanges() throws {
        for change in ["page", "assignment", "programs", "encoding"] {
            let (gateway, _) = try fixture()
            let discovery = try call(gateway, "discover").objectValue!
            _ = try call(gateway, "feedback", ["expected": discovery["expected"]!, "expected_sequence": .string("0"),
                                               "control_id": .string("pushEncoder.1.5"), "kind": .string("value"),
                                               "value": .number(127)])
            XCTAssertEqual(gateway.session.mock.value(of: .pushEncoder(group: 1, 5)), 127)
            switch change {
            case "page":
                var configuration = gateway.session.engine.configuration
                try configuration.addPage(.init(id: "other", name: "Other", assignments: [
                    .init(control: .pushEncoder(group: 1, 5), target: .parameter("simulation.arm"))
                ]))
                try gateway.session.updatePrograms(configuration)
                try gateway.session.selectPage("other")
            case "assignment":
                try gateway.session.setAssignment(
                    .init(control: .pushEncoder(group: 1, 5), target: .parameter("simulation.arm")),
                    for: .pushEncoder(group: 1, 5)
                )
            case "programs":
                var configuration = gateway.session.engine.configuration
                try configuration.assign(.init(
                    control: .pushEncoder(group: 1, 5),
                    target: .parameter("simulation.arm")
                ))
                try gateway.session.updatePrograms(configuration)
            default: try gateway.session.setMockNRPN(true, for: .pushEncoder(group: 1, 5))
            }
            XCTAssertEqual(gateway.session.mock.value(of: .pushEncoder(group: 1, 5)), 0, change)
            let snapshot = try call(gateway, "snapshot", ["instance_id": .string("fixture")]).objectValue!
            XCTAssertEqual(snapshot["feedback"], .object([:]), change)
            XCTAssertNotEqual(snapshot["discovery"]?.objectValue?["expected"], discovery["expected"], change)
            let stale = gateway.call("surface_control_input", arguments: .object([
                "expected": discovery["expected"]!, "expected_sequence": .string("0"),
                "control_id": .string("pushEncoder.1.1"), "encoding": .string("scalar"), "value": .number(127)
            ]))
            // Contract 1.1 validates mapping before epoch: each of these changes the mapping document.
            XCTAssertEqual(stale.value.objectValue?["code"], .string("stale_mapping"), change)
            XCTAssertNotEqual(snapshot["discovery"]?.objectValue?["expected"]?.objectValue?["mapping_revision"],
                              discovery["expected"]?.objectValue?["mapping_revision"], change)
        }
        // A context change that leaves the mapping intact keeps the revision and reports stale_epoch.
        let (gateway, _) = try fixture()
        let discovery = try call(gateway, "discover").objectValue!
        gateway.session.selectSource(.hardware)
        gateway.session.selectSource(.mock)
        let current = try call(gateway, "discover").objectValue!
        XCTAssertEqual(current["expected"]?.objectValue?["mapping_revision"],
                       discovery["expected"]?.objectValue?["mapping_revision"])
        let stale = gateway.call("surface_control_input", arguments: .object([
            "expected": discovery["expected"]!, "expected_sequence": .string("0"),
            "control_id": .string("pushEncoder.1.1"), "encoding": .string("scalar"), "value": .number(127)
        ]))
        XCTAssertEqual(stale.value.objectValue?["code"], .string("stale_epoch"))
    }

    func testNewToolsReportRateLimitWithoutConsumingInputSequence() throws {
        let (gateway, _) = try fixture()
        gateway.permissions.writesPerSecond = 1
        _ = try write(gateway, value: .number(100))
        let discovery = try call(gateway, "discover").objectValue!
        let result = gateway.call("surface_control_input", arguments: .object([
            "expected": discovery["expected"]!, "expected_sequence": discovery["latest_sequence"]!,
            "control_id": .string("pushEncoder.1.2"), "encoding": .string("scalar"), "value": .number(100)
        ]))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.value.objectValue?["code"], .string("rate_limited"))
        XCTAssertEqual(try call(gateway, "discover").objectValue?["latest_sequence"], .string("1"))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.start"), 0)
    }
}
