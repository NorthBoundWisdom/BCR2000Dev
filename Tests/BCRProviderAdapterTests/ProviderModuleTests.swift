import BCRFoundation
import BCRSurfaceDomain
import BCRProviderApplication
import BCRMCPAdapter
import BCRProviderMCPAdapter
import BCRHTTPTransport
import Foundation
import XCTest

@MainActor
final class ProviderModuleTests: XCTestCase {
    func context(
        console: Bool = true,
        configuration: ProviderConfiguration = .init(robot: true, chassis: true, clock: .manual),
        permissions: MCPPermissions = .init()
    ) throws -> (MCPApplicationGateway, ProviderApplication) {
        let session = console ? SurfaceSession(
            hardwareDevice: MockSurfaceDevice(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        ) : nil
        let gateway = MCPApplicationGateway(session: session, permissions: permissions, includeAgent: false)
        let application = ProviderApplication(configuration: configuration)
        try ProviderMCPModule.install(on: gateway, application: application)
        return (gateway, application)
    }

    func call(_ gateway: MCPApplicationGateway, _ name: String,
              _ arguments: JSONValue = .object([:])) throws -> JSONValue
    {
        let result = gateway.call(name, arguments: arguments)
        XCTAssertFalse(result.isError, "\(name): \(result.value)")
        return result.value
    }

    func testOptionalModulesHaveNoSyntheticFallbackOrAgentRuntime() throws {
        let (gateway, application) = try context(console: false, configuration: .init())
        let names = gateway.toolDefinitions.compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertFalse(names.contains("robot_state"))
        XCTAssertFalse(names.contains("chassis_command"))
        XCTAssertFalse(names.contains("console_events"))
        XCTAssertFalse(names.contains("get_agents"))
        let unsupported = gateway.call("robot_state", arguments: .object([:]))
        XCTAssertTrue(unsupported.isError)
        XCTAssertEqual(unsupported.value.objectValue?["error"]?.objectValue?["code"], .string("unsupported"))
        XCTAssertThrowsError(try application.robotState())
        let caps = try call(gateway, "provider_capabilities")
        XCTAssertEqual(caps.objectValue?["console"]?.objectValue?["enabled"], .bool(false))
    }

    func testAgentAndConsolePermissionCannotEnableRobotOrChassis() throws {
        let (gateway, app) = try context(permissions: MCPPermissions(agentControl: true, deviceControl: true))
        let robot = try app.robotState()
        let denied = gateway.call("robot_command", arguments: .object([
            "schema_version": .number(1), "device_id": .string("robot.reference"), "operation": .string("initialize"),
            "generation": .string(robot.metadata.generation), "initial_joints_rad": .array(Array(
                repeating: .number(0),
                count: 6
            ))
        ]))
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(denied.value.objectValue?["error"]?.objectValue?["code"], .string("permission_denied"))
        XCTAssertNil(try app.robotState().actual)
        XCTAssertNil(try app.chassisState().actual)
    }

    func testStrictSchemasRejectExtraFieldsBeforeStateMutation() throws {
        let (gateway, app) = try context(permissions: .init(robotControl: true))
        let generation = try app.robotState().metadata.generation
        let bad = gateway.call("robot_command", arguments: .object([
            "schema_version": .number(1), "device_id": .string("robot.reference"), "operation": .string("initialize"),
            "generation": .string(generation), "initial_joints_rad": .array(Array(repeating: .number(0), count: 6)),
            "joint_units": .string("degrees")
        ]))
        XCTAssertTrue(bad.isError)
        XCTAssertNil(try app.robotState().actual)
        XCTAssertEqual(try app.robotState().metadata.generation, generation)
    }

    func testModuleRegistrationRejectsCollisionsAtomically() throws {
        let (gateway, _) = try context()
        let before = gateway.toolDefinitions
        let tool = JSONValue.object(["name": .string("provider_state"), "inputSchema": .object([:])])
        XCTAssertThrowsError(try gateway.registerModule(id: "duplicate", tools: [tool]) { _, _ in .null })
        XCTAssertEqual(gateway.toolDefinitions, before)
    }

    func testSyntheticConsoleInputCannotWriteProtectedValueOrPretendHardware() throws {
        let (gateway, _) = try context(permissions: .init(configurationWrite: true, deviceControl: true))
        let session = gateway.session
        try session.addParameter(.init(
            id: "generic.protected",
            name: "Protected",
            minimum: 0,
            maximum: 1,
            externallyProtected: true
        ))
        try session.setAssignment(
            .init(control: .pushEncoder(group: 1, 1), target: .parameter("generic.protected")),
            for: .pushEncoder(group: 1, 1)
        )
        let args: JSONValue = .object([
            "operation": .string("turn"),
            "control": try .encoded(BCRControlID.pushEncoder(group: 1, 1)),
            "delta": .number(127)
        ])
        XCTAssertTrue(gateway.call("console_mock_input", arguments: args).isError)
        XCTAssertEqual(session.engine.value(of: "generic.protected"), 0)
        try session.setAssignment(
            .init(control: .pushEncoder(group: 1, 1), target: .parameter("general.1")),
            for: .pushEncoder(group: 1, 1)
        )
        _ = try call(gateway, "console_mock_input", args)
        let events = try call(gateway, "console_events", .object(["schema_version": .number(1)]))
        let accepted = events.objectValue?["events"]?.arrayValue?
            .filter { $0.objectValue?["kind"] == .string("control.input") } ?? []
        XCTAssertFalse(accepted.isEmpty)
        XCTAssertTrue(accepted
            .allSatisfy {
                $0.objectValue?["source"] == .string("mock") && $0.objectValue?["payload"]?
                    .objectValue?["origin"] == .string("agent")
            })
    }

    func testLegacyMockInputRequiresBothPermissionsAndCannotSelectHardware() throws {
        let (gateway, _) = try context(permissions: .init(parameterWrite: false, deviceControl: true))
        let control = BCRControlID.pushEncoder(group: 1, 1)
        let args: JSONValue = .object([
            "operation": .string("turn"), "control": try .encoded(control), "delta": .number(10)
        ])
        let initial = gateway.session.engine.value(of: "general.1")
        for permissions in [MCPPermissions(parameterWrite: false, deviceControl: true),
                            MCPPermissions(parameterWrite: true, deviceControl: false)]
        {
            gateway.permissions = permissions
            let result = gateway.call("console_mock_input", arguments: args)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.value.objectValue?["error"]?.objectValue?["code"], .string("permission_denied"))
            XCTAssertEqual(gateway.session.engine.value(of: "general.1"), initial)
        }
        gateway.permissions = .init(deviceControl: true)
        gateway.session.selectSource(.hardware)
        let generation = gateway.session.inputEvents.generation
        let result = gateway.call("console_mock_input", arguments: args)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.value.objectValue?["error"]?.objectValue?["code"], .string("unsupported"))
        XCTAssertEqual(gateway.session.engine.value(of: "general.1"), initial)
        XCTAssertEqual(gateway.session.inputEvents.generation, generation)
        let forged: JSONValue = .object([
            "operation": .string("turn"), "control": try .encoded(control), "delta": .number(10),
            "source": .string("hardware")
        ])
        XCTAssertTrue(gateway.call("console_mock_input", arguments: forged).isError)
    }

    func testLegacyMockInputCannotInvokeActionOrReadonlyParameter() throws {
        let (gateway, _) = try context(permissions: .init(deviceControl: true))
        let control = BCRControlID.button(row: 1, 1)
        var actionCount = 0
        gateway.session.onTriggerAgent = { _ in actionCount += 1 }
        try gateway.session.setAssignment(.init(control: control, target: .agentPrimaryAction(AgentSlotID(1))),
                                          for: control)
        let args: JSONValue = .object(["operation": .string("press"), "control": try .encoded(control)])
        let action = gateway.call("console_mock_input", arguments: args)
        XCTAssertTrue(action.isError)
        XCTAssertEqual(action.value.objectValue?["error"]?.objectValue?["code"], .string("permission_denied"))
        XCTAssertEqual(actionCount, 0)
        try gateway.session.addParameter(.init(id: "readonly", name: "Read only", minimum: 0, maximum: 1,
                                               kind: .toggle, agentWritable: false))
        try gateway.session.setAssignment(.init(control: control, target: .parameter("readonly")), for: control)
        let readonly = gateway.call("console_mock_input", arguments: args)
        XCTAssertTrue(readonly.isError)
        XCTAssertEqual(readonly.value.objectValue?["error"]?.objectValue?["code"], .string("permission_denied"))
        XCTAssertEqual(gateway.session.engine.value(of: "readonly"), 0)
    }

    func testLegacyProviderInstancesKeepInputsAndEpochsIsolated() throws {
        let (first, _) = try context(permissions: .init(deviceControl: true))
        let (second, _) = try context(permissions: .init(deviceControl: true))
        let secondGeneration = second.session.inputEvents.generation
        let secondSnapshot = second.session.inputEvents.snapshot()
        XCTAssertNotEqual(first.session.inputEvents.generation, secondGeneration)
        _ = try call(first, "console_mock_input", .object([
            "operation": .string("turn"), "control": try .encoded(BCRControlID.pushEncoder(group: 1, 1)),
            "delta": .number(25)
        ]))
        XCTAssertGreaterThan(first.session.engine.value(of: "general.1") ?? 0, 0)
        XCTAssertEqual(second.session.engine.value(of: "general.1"), 0)
        first.session.selectSource(.hardware)
        XCTAssertEqual(second.session.inputEvents.generation, secondGeneration)
        XCTAssertEqual(second.session.inputEvents.snapshot(), secondSnapshot)
    }

    func testManualTimeAndDeviceResetDoNotMutateConsoleOrAnotherDevice() throws {
        let (gateway, app) = try context(permissions: .init(
            robotControl: true,
            chassisControl: true,
            simulationControl: true
        ))
        let consoleGeneration = gateway.session.inputEvents.generation
        let chassis = try JSONValue.encoded(app.chassisState())
        let before = try app.robotState()
        _ = try app.executeRobot(
            .initialize(before.metadata.generation, Array(repeating: 0, count: 6)),
            access: .init(write: true, robot: true, chassis: false, simulation: true)
        )
        try app.advance(
            domain: "robot",
            dt: 0.1,
            access: .init(write: true, robot: true, chassis: false, simulation: true)
        )
        XCTAssertEqual(try JSONValue.encoded(app.chassisState()), chassis)
        XCTAssertEqual(gateway.session.inputEvents.generation, consoleGeneration)
        _ = try app.executeRobot(
            .reset(app.robotState().metadata.generation),
            access: .init(write: true, robot: true, chassis: false, simulation: true)
        )
        XCTAssertEqual(try JSONValue.encoded(app.chassisState()), chassis)
        XCTAssertEqual(gateway.session.inputEvents.generation, consoleGeneration)
    }

    func testRealtimeLeaseWatchdogAdvancesWithoutAStatePoll() async throws {
        let app = ProviderApplication(configuration: .init(robot: false, chassis: true, clock: .realtime))
        let access = ProviderAccess(write: true, robot: false, chassis: true, simulation: true)
        var state = try app.chassisState()
        state = try app.executeChassis(.initialize(state.metadata.generation, [0, 0, 0]), access: access).state
        let result = try app.executeChassis(.acquire(state.metadata.generation, "fixture", 0.2), access: access)
        let grant = try XCTUnwrap(result.control)
        func proof(_ sequence: Int) -> DeviceCommandProof { .init(
            generation: grant.generation,
            token: grant.control_token,
            sequence: sequence
        ) }
        _ = try app.executeChassis(.enable(proof(1)), access: access)
        _ = try app.executeChassis(.drive(proof(2), 0.5, 0, 0.15), access: access)
        app.start(); defer { app.stopClock() }
        try await Task.sleep(for: .milliseconds(650))
        let stopped = try app.chassisState()
        XCTAssertTrue(stopped.stopped)
        XCTAssertFalse(stopped.metadata.enabled)
        XCTAssertNil(stopped.metadata.control_owner)
        XCTAssertGreaterThan(try XCTUnwrap(stopped.actual).pose_m_rad[0], 0)
    }

    func testRevokingOneDomainInvalidatesItsControlWithoutResettingPeer() throws {
        let (gateway, app) = try context(permissions: .init(
            robotControl: true,
            chassisControl: true,
            simulationControl: true
        ))
        let access = ProviderAccess(write: true, robot: true, chassis: true, simulation: true)
        var state = try app.robotState()
        state = try app.executeRobot(
            .initialize(state.metadata.generation, Array(repeating: 0, count: 6)),
            access: access
        ).state
        let grant = try XCTUnwrap(app.executeRobot(.acquire(state.metadata.generation, "fixture", 5), access: access)
            .control)
        func proof(_ n: Int) -> DeviceCommandProof { .init(
            generation: grant.generation,
            token: grant.control_token,
            sequence: n
        ) }
        _ = try app.executeRobot(.enable(proof(1)), access: access)
        _ = try app.executeRobot(.move(proof(2), [0.4, 0, 0, 0, 0, 0], 1, 2), access: access)
        for _ in 0 ..< 4 { try app.advance(domain: "robot", dt: 0.1, access: access) }
        let peer = try JSONValue.encoded(app.chassisState())
        gateway.permissions.robotControl = false
        let revoked = try app.robotState()
        XCTAssertFalse(revoked.metadata.enabled)
        XCTAssertNil(revoked.metadata.control_owner)
        XCTAssertNotEqual(revoked.metadata.generation, grant.generation)
        XCTAssertNil(revoked.target_joints_rad)
        XCTAssertEqual(try JSONValue.encoded(app.chassisState()), peer)
        gateway.permissions.robotControl = true
        XCTAssertThrowsError(try app.executeRobot(.enable(proof(3)), access: access))
        for _ in 0 ..< 5 { try app.advance(domain: "robot", dt: 0.1, access: access) }
        XCTAssertTrue(try app.robotState().stopped)
        XCTAssertFalse(try app.robotState().metadata.enabled)
    }

    func testReadOnlyRevocationProducesAutonomousBoundedStopAndNoRevival() async throws {
        let (gateway, app) = try context(configuration: .init(robot: false, chassis: true, clock: .realtime),
                                         permissions: .init(chassisControl: true, simulationControl: true))
        let access = ProviderAccess(write: true, robot: false, chassis: true, simulation: true)
        var state = try app.chassisState()
        state = try app.executeChassis(.initialize(state.metadata.generation, [0, 0, 0]), access: access).state
        let grant = try XCTUnwrap(app.executeChassis(.acquire(state.metadata.generation, "fixture", 5), access: access)
            .control)
        func proof(_ n: Int) -> DeviceCommandProof { .init(
            generation: grant.generation,
            token: grant.control_token,
            sequence: n
        ) }
        _ = try app.executeChassis(.enable(proof(1)), access: access)
        _ = try app.executeChassis(.drive(proof(2), 0.8, 0.2, 2), access: access)
        app.start(); defer { app.stopClock() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(try XCTUnwrap(app.chassisState().actual).speed_m_s, 0)
        gateway.permissions.parameterWrite = false
        XCTAssertFalse(try app.chassisState().metadata.enabled)
        XCTAssertNil(try app.chassisState().metadata.control_owner)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(try app.chassisState().stopped)
        gateway.permissions.parameterWrite = true
        XCTAssertThrowsError(try app.executeChassis(.drive(proof(3), 0.5, 0, 1), access: access))
        XCTAssertEqual(try app.chassisState().target_speed_m_s, 0)
    }
}
