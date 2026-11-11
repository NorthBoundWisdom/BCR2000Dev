import Foundation
import XCTest
@testable import BCRAgentCore
@testable import BCRMCPAdapter
@testable import BCRSurfaceDomain

@MainActor
private final class MCPFakeDevice: SurfaceDevice {
    var connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func send(_ message: MIDIVoiceMessage) throws {}
}

@MainActor
private final class MCPTestClock {
    var time = Date(timeIntervalSinceReferenceDate: 1_000)
}

@MainActor
final class MCPTests: XCTestCase {
    private func makeService(clock: MCPTestClock = MCPTestClock()) -> AgentControlService {
        AgentControlService(session: SurfaceSession(
            hardwareDevice: MCPFakeDevice(), configuration: .robotArmDemo(), now: { clock.time },
            saveHardwareMap: { _ in }, saveConfiguration: { _ in }
        ), now: { clock.time })
    }

    private func modern(_ method: String, params: [String: JSONValue] = [:],
                        id: JSONValue = .number(1)) throws -> Data
    {
        var params = params
        params["_meta"] = .object([
            "io.modelcontextprotocol/protocolVersion": .string(MCPVersions.current),
            "io.modelcontextprotocol/clientCapabilities": .object([:])
        ])
        return try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": .object(params)
        ]))
    }

    private func headers(_ method: String, name: String? = nil) -> [String: String] {
        var headers = ["mcp-protocol-version": MCPVersions.current, "mcp-method": method]
        if let name { headers["mcp-name"] = name }
        return headers
    }

    func testAgentSlotErrorsAreExplicitAndDoNotInvokeHandler() {
        let service = makeService()
        service.permissions.agentControl = true
        var calls = 0
        service.onAgentAction = { _, _ in calls += 1 }
        for args: [String: JSONValue] in [[:], ["slot": .number(0)], ["slot": .number(9)], ["slot": .double(1.5)]] {
            let result = service.call("start_agent", arguments: .object(args))
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.value.objectValue?["error"], .string(L10n.text("Agent 槽位必须为 1–8")))
        }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(service.call("start_agent", arguments: .object(["slot": .double(1)])).isError)
        XCTAssertEqual(calls, 1)
    }

    func testNewControlPermissionsDefaultOffAndAreEnforced() throws {
        let old = Data(#"{"parameterWrite":true,"configurationWrite":false,"writesPerSecond":60}"#.utf8)
        let permissions = try JSONDecoder().decode(MCPPermissions.self, from: old)
        XCTAssertFalse(permissions.agentControl)
        XCTAssertFalse(permissions.deviceControl)
        let session = SurfaceSession(
            hardwareDevice: MCPFakeDevice(),
            configuration: .robotArmDemo(), saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let service = AgentControlService(session: session)
        var calls = 0
        service.onAgentAction = { _, _ in calls += 1 }
        XCTAssertTrue(service.call("start_agent", arguments: .object(["slot": .number(1)])).isError)
        XCTAssertEqual(calls, 0)
        service.permissions.agentControl = true
        XCTAssertFalse(service.call("start_agent", arguments: .object(["slot": .number(1)])).isError)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(service.call("start_agent", arguments: .object(["slot": .number(9)])).isError)
        XCTAssertTrue(service.call("set_device_source", arguments: .object(["source": .string("hardware")])).isError)
    }

    func testToolSchemasAndReadToolsAreClientNeutral() async throws {
        let service = makeService()
        XCTAssertEqual(MCPToolCatalog.tools.count, MCPToolCatalog.names.count)
        for tool in MCPToolCatalog.tools {
            let object = try XCTUnwrap(tool.objectValue)
            XCTAssertNotNil(object["inputSchema"]?.objectValue?["properties"])
            XCTAssertNotNil(object["outputSchema"]?.objectValue?["properties"])
            XCTAssertNotNil(object["annotations"])
        }
        XCTAssertFalse(service.call("get_status").isError)
        XCTAssertEqual(service.call("list_parameters").value.arrayValue?.count, 9)
        XCTAssertEqual(service.call("list_controls").value.arrayValue?.count, 108)
        XCTAssertFalse(service.call("get_parameter", arguments: .object(["id": .string("arm.j1")])).isError)
        XCTAssertTrue(service.call("get_parameter", arguments: .object(["id": .string("missing")])).isError)
        XCTAssertTrue(service.call("missing").isError)
        XCTAssertTrue(service.call("get_status", arguments: .object(["unexpected": .number(1)])).isError)
        XCTAssertTrue(service.call("set_parameter", arguments: .object(["id": .string("arm.j1")])).isError)
    }

    func testAgentWriteClampsUpdatesMockAndMarksOrigin() async {
        let service = makeService()
        let result = service.call("set_parameter", arguments: .object(["id": .string("arm.j1"), "value": .number(999)]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.value.objectValue?["value"], .double(180))
        XCTAssertEqual(result.value.objectValue?["clamped"], .bool(true))
        XCTAssertEqual(service.session.mock.value(of: .pushEncoder(group: 1, 1)), 127)
        XCTAssertEqual(service.session.events.last?.origin, .agent)
        service.session.setParameter("arm.j1", to: 0)
        XCTAssertEqual(service.session.events.last?.origin, .software)
        XCTAssertFalse(service.call(
            "nudge_parameter",
            arguments: .object(["id": .string("arm.j1"), "delta": .number(10)])
        ).isError)
        XCTAssertEqual(service.session.engine.value(of: "arm.j1"), 10)
        XCTAssertTrue(service.call(
            "nudge_parameter",
            arguments: .object(["id": .string("missing"), "delta": .number(10)])
        ).isError)
        XCTAssertTrue(service.call(
            "set_parameter",
            arguments: .object(["id": .string("arm.j1"), "value": .double(.nan)])
        ).isError)
    }

    func testSourceAndLearnToolsRequireLocalConfigurationPermissionAndHardware() async throws {
        let device = MCPFakeDevice()
        let session = SurfaceSession(
            hardwareDevice: device,
            configuration: .robotArmDemo(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let service = AgentControlService(session: session)
        let source: JSONValue = .object(["source": .string("hardware")])
        let control = BCRControlID.button(row: 2, 2)
        let learn: JSONValue = .object(["control": try .encoded(control)])
        XCTAssertTrue(service.call("set_device_source", arguments: source).isError)
        XCTAssertTrue(service.call("begin_control_learn", arguments: learn).isError)
        XCTAssertTrue(service.call("stop_control_learn").isError)
        service.permissions.configurationWrite = true
        service.permissions.deviceControl = true
        service.onSelectSource = { session.selectSource($0) }
        XCTAssertTrue(service.call("set_device_source", arguments: source).isError)
        XCTAssertEqual(session.source, .mock)
        device.connection = MIDIConnectionSnapshot(connectedSource: "BCR Port 1", connectedDestination: "BCR Port 1")
        device.onConnection?(device.connection)
        XCTAssertTrue(service.call("begin_control_learn", arguments: learn).isError)
        XCTAssertFalse(service.call("set_device_source", arguments: source).isError)
        XCTAssertEqual(session.source, .hardware)
        XCTAssertFalse(service.call("begin_control_learn", arguments: learn).isError)
        XCTAssertEqual(session.engine.learnTarget, control)
        XCTAssertTrue(service.call("set_device_source", arguments: .object(["source": .string("mock")])).isError)
        XCTAssertFalse(service.call("stop_control_learn").isError)
        XCTAssertNil(session.engine.learnTarget)
        XCTAssertTrue(service.call("set_device_source", arguments: .object(["source": .string("unknown")])).isError)
    }

    func testLearnUsesRealInputPathAndCannotOverwriteExistingBinding() async throws {
        let device = MCPFakeDevice()
        device.connection = MIDIConnectionSnapshot(connectedSource: "BCR Port 1", connectedDestination: "BCR Port 1")
        var saved: [HardwareMap] = []
        let session = SurfaceSession(
            hardwareDevice: device,
            configuration: .robotArmDemo(), saveHardwareMap: { saved.append($0) },
            saveConfiguration: { _ in }
        )
        let service = AgentControlService(
            session: session,
            permissions: MCPPermissions(configurationWrite: true, deviceControl: true)
        )
        service.onSelectSource = { session.selectSource($0) }
        XCTAssertFalse(service.call("set_device_source", arguments: .object(["source": .string("hardware")])).isError)
        let control = BCRControlID.button(row: 2, 2)
        let learn: JSONValue = .object(["control": try .encoded(control)])
        XCTAssertFalse(service.call("begin_control_learn", arguments: learn).isError)
        XCTAssertNil(session.engine.hardwareMap.midi(for: control))
        device.onMessages?([.controlChange(channel: 0, number: 70, value: 127)])
        XCTAssertEqual(session.engine.hardwareMap.midi(for: control)?.number, 70)
        XCTAssertEqual(saved.count, 1)
        XCTAssertFalse(service.call("stop_control_learn").isError)
        XCTAssertTrue(service.call("begin_control_learn", arguments: learn).isError)
        XCTAssertEqual(saved.count, 1)
    }

    func testRestrictConfigurationWritePersistsBeforeRevocationAndCannotRegrant() async {
        let service = makeService()
        service.permissions.configurationWrite = true
        service.onRestrictConfigurationWrite = { throw MCPToolFailure("fixture save failure") }
        XCTAssertTrue(service.call("restrict_configuration_write").isError)
        XCTAssertTrue(service.permissions.configurationWrite)
        var persisted = false
        service.onRestrictConfigurationWrite = { persisted = true }
        XCTAssertFalse(service.call("restrict_configuration_write").isError)
        XCTAssertTrue(persisted)
        XCTAssertFalse(service.permissions.configurationWrite)
        XCTAssertTrue(service.permissions.parameterWrite)
        XCTAssertTrue(service.call("restrict_configuration_write", arguments: .object(["enabled": .bool(true)]))
            .isError)
    }

    func testDeviceSourceAndLearningRefuseActiveExternalOutput() async throws {
        let device = MCPFakeDevice()
        device.connection = MIDIConnectionSnapshot(connectedSource: "BCR Port 1", connectedDestination: "BCR Port 1")
        let session = SurfaceSession(
            hardwareDevice: device,
            configuration: .robotArmDemo(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let service = AgentControlService(
            session: session,
            permissions: MCPPermissions(configurationWrite: true, deviceControl: true)
        )
        service.onSelectSource = { session.selectSource($0) }
        session.setMotionSafety(MotionSafetySnapshot(
            status: .ready,
            reason: "fixture",
            outputs: [:],
            actual: [:],
            limited: false
        ))
        XCTAssertTrue(service.call("set_device_source", arguments: .object(["source": .string("hardware")])).isError)
        session.setMotionSafety(MotionSafetySnapshot(
            status: .disconnected,
            reason: "fixture",
            outputs: [:],
            actual: [:],
            limited: false
        ))
        XCTAssertFalse(service.call("set_device_source", arguments: .object(["source": .string("hardware")])).isError)
        session.setMotionSafety(MotionSafetySnapshot(
            status: .ready,
            reason: "fixture",
            outputs: [:],
            actual: [:],
            limited: false
        ))
        XCTAssertTrue(service.call(
            "begin_control_learn",
            arguments: .object(["control": try .encoded(BCRControlID.button(row: 2, 2))])
        ).isError)
        XCTAssertNil(session.engine.learnTarget)
    }

    func testProtectedParametersReadOnlyAndAtomicBatchFailures() async {
        let service = makeService()
        let before = service.session.engine.parameterValues
        let batch: JSONValue = .object(["values": .array([
            .object(["id": .string("arm.j1"), "value": .number(90)]),
            .object(["id": .string("arm.enabled"), "value": .number(1)])
        ])])
        XCTAssertTrue(service.call("set_parameters", arguments: batch).isError)
        XCTAssertEqual(service.session.engine.parameterValues, before)
        XCTAssertTrue(service.session.events.isEmpty)
        XCTAssertTrue(service.call(
            "set_parameter",
            arguments: .object(["id": .string("arm.enabled"), "value": .number(1)])
        ).isError)
        XCTAssertFalse(service.call(
            "reset_group",
            arguments: .object(["group": .string(SurfaceConfiguration.robotArmGroup)])
        ).isError)
        XCTAssertEqual(service.session.engine.parameterValues, before)
        service.permissions.parameterWrite = false
        XCTAssertTrue(service.call("set_parameter", arguments: .object(["id": .string("arm.j1"), "value": .number(90)]))
            .isError)
        XCTAssertFalse(service.call("get_status").isError)
    }

    func testBatchSuccessDuplicateAndUnknownParameterFailures() async {
        let service = makeService()
        let valid: JSONValue = .object(["values": .array([
            .object(["id": .string("arm.j1"), "value": .number(90)]),
            .object(["id": .string("arm.j2"), "value": .number(20)])
        ])])
        XCTAssertFalse(service.call("set_parameters", arguments: valid).isError)
        XCTAssertEqual(service.session.engine.value(of: "arm.j1"), 90)
        XCTAssertEqual(service.session.engine.value(of: "arm.j2"), 20)
        let before = service.session.engine.parameterValues
        for id in ["arm.j1", "missing"] {
            XCTAssertTrue(service.call("set_parameters", arguments: .object(["values": .array([
                .object(["id": .string("arm.j1"), "value": .number(0)]),
                .object(["id": .string(id), "value": .number(1)])
            ])])).isError)
            XCTAssertEqual(service.session.engine.parameterValues, before)
        }
        XCTAssertTrue(service.call("set_parameters", arguments: .object(["values": .array([])])).isError)
    }

    func testConfigurationToolsRequirePermissionAndValidateBeforeChangingState() async throws {
        let service = makeService()
        var definition = ParameterDefinition(id: "test", name: "Test", group: "test", defaultValue: 10)
        let create: JSONValue = .object(["definition": try .encoded(definition)])
        XCTAssertTrue(service.call("create_parameter", arguments: create).isError)
        XCTAssertTrue(service.call("update_parameter", arguments: create).isError)
        let assignment = ControlAssignment(control: .encoder(row: 1, 1), target: .parameter("test"))
        let assign: JSONValue = .object(["assignment": try .encoded(assignment)])
        XCTAssertTrue(service.call("assign_control", arguments: assign).isError)
        service.permissions.configurationWrite = true
        XCTAssertFalse(service.call("create_parameter", arguments: create).isError)
        XCTAssertTrue(service.call("create_parameter", arguments: create).isError)
        XCTAssertFalse(service.call("assign_control", arguments: assign).isError)
        definition.name = "Renamed"
        XCTAssertFalse(service.call("update_parameter", arguments: .object(["definition": try .encoded(definition)]))
            .isError)
        XCTAssertEqual(service.session.engine.configuration.parameter("test")?.name, "Renamed")
        XCTAssertFalse(service.call("set_parameter", arguments: .object(["id": .string("test"), "value": .number(80)]))
            .isError)
        XCTAssertFalse(service.call("reset_group", arguments: .object(["group": .string("test")])).isError)
        XCTAssertEqual(service.session.engine.value(of: "test"), 10)
        XCTAssertTrue(service.call("reset_group", arguments: .object(["group": .string("missing")])).isError)
        definition.maximum = -1
        let before = service.session.engine.configuration
        XCTAssertTrue(service.call("update_parameter", arguments: .object(["definition": try .encoded(definition)]))
            .isError)
        XCTAssertEqual(service.session.engine.configuration, before)
        XCTAssertTrue(service.call("assign_control", arguments: .object(["assignment": try .encoded(
            ControlAssignment(control: .encoder(row: 1, 1), target: .agentPrimaryAction(AgentSlotID(1)))
        )])).isError)
    }

    func testWriteRateLimitUsesInjectedClockAndCountsBatchMembers() async {
        let clock = MCPTestClock()
        let service = makeService(clock: clock)
        service.permissions.writesPerSecond = 2
        let one: JSONValue = .object(["id": .string("arm.j1"), "value": .number(30)])
        XCTAssertFalse(service.call("set_parameter", arguments: one).isError)
        XCTAssertTrue(service.call("set_parameters", arguments: .object(["values": .array([
            .object(["id": .string("arm.j1"), "value": .number(50)]),
            .object(["id": .string("arm.j2"), "value": .number(50)])
        ])])).isError)
        XCTAssertEqual(service.session.engine.value(of: "arm.j1"), 30)
        XCTAssertFalse(service.call("set_parameter", arguments: one).isError)
        XCTAssertTrue(service.call("set_parameter", arguments: one).isError)
        clock.time.addTimeInterval(1)
        XCTAssertFalse(service.call("set_parameter", arguments: one).isError)
    }

    func testAuditIsBoundedAndDoesNotRetainRequestArguments() async {
        let service = makeService()
        for _ in 0 ..< 110 { _ = service.call("get_status") }
        XCTAssertEqual(service.audit.count, 100)
        XCTAssertTrue(service.audit.allSatisfy { $0.method == "get_status" && $0.detail == L10n.text("完成") })
    }

    func testModernDiscoveryToolCallsAndVersionMetadata() async throws {
        let router = MCPRouter(service: makeService())
        let discovery = router.handle(try modern("server/discover"), headers: headers("server/discover"))
        XCTAssertEqual(discovery.status, 200)
        XCTAssertNil(discovery.sessionID)
        XCTAssertEqual(discovery.body?.objectValue?["result"]?.objectValue?["resultType"], .string("complete"))
        XCTAssertEqual(router.sessionCount, 0)
        let tools = router.handle(try modern("tools/list"), headers: headers("tools/list"))
        XCTAssertEqual(
            tools.body?.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.count,
            MCPToolCatalog.names.count
        )
        let call = router.handle(try modern("tools/call", params: [
            "name": .string("set_parameter"), "arguments": .object(["id": .string("arm.j1"), "value": .number(90)])
        ]), headers: headers("tools/call", name: "set_parameter"))
        XCTAssertEqual(call.body?.objectValue?["result"]?.objectValue?["isError"], .bool(false))
        XCTAssertEqual(router.service.session.engine.value(of: "arm.j1"), 90)
        XCTAssertEqual(router.handle(try modern("ping"), headers: headers("ping")).status, 200)
        XCTAssertEqual(router.handle(try modern("unknown"), headers: headers("unknown")).status, 404)
    }

    func testHeaderMismatchMalformedRequestsAndUnsupportedVersionsAreExplicit() async throws {
        let router = MCPRouter(service: makeService())
        XCTAssertEqual(router.handle(try modern("ping"), headers: headers("tools/list")).status, 400)
        XCTAssertEqual(
            router.handle(Data("{".utf8), headers: [:]).body?.objectValue?["error"]?.objectValue?["code"],
            .number(-32700)
        )
        XCTAssertEqual(router.handle(Data("[]".utf8), headers: [:]).status, 400)
        XCTAssertEqual(router.handle(try modern("ping", id: .bool(true)), headers: headers("ping")).status, 400)
        var raw = try JSONDecoder().decode(JSONValue.self, from: modern("ping")).objectValue!
        var params = raw["params"]!.objectValue!
        var meta = params["_meta"]!.objectValue!
        meta["io.modelcontextprotocol/protocolVersion"] = .string("2099-01-01")
        params["_meta"] = .object(meta); raw["params"] = .object(params)
        let reply = router.handle(try JSONEncoder().encode(JSONValue.object(raw)),
                                  headers: ["mcp-method": "ping", "mcp-protocol-version": "2099-01-01"])
        XCTAssertEqual(reply.status, 400)
        XCTAssertEqual(reply.body?.objectValue?["error"]?.objectValue?["code"], .number(-32022))
    }

    func testLegacyHandshakeSessionExpiryAndStop() async throws {
        let clock = MCPTestClock()
        let router = MCPRouter(service: makeService(clock: clock), now: { clock.time })
        let initialization: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string(MCPVersions.legacy), "capabilities": .object([:]),
                               "clientInfo": .object(["name": .string("generic-test"), "version": .string("1")])])
        ])
        let reply = router.handle(try JSONEncoder().encode(initialization), headers: [:])
        let session = try XCTUnwrap(reply.sessionID)
        let h = ["mcp-session-id": session, "mcp-protocol-version": MCPVersions.legacy]
        let ping = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(2),
            "method": .string("ping")
        ]))
        XCTAssertNotNil(router.handle(ping, headers: h).body?.objectValue?["error"])
        let ready = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]))
        XCTAssertEqual(router.handle(ready, headers: h).status, 202)
        XCTAssertEqual(router.handle(ping, headers: h).status, 200)
        clock.time.addTimeInterval(1_801)
        XCTAssertEqual(router.handle(ping, headers: h).status, 404)
        XCTAssertEqual(router.sessionCount, 0)
        _ = router.handle(try JSONEncoder().encode(initialization), headers: [:])
        router.stop()
        XCTAssertEqual(router.sessionCount, 0)
        XCTAssertEqual(router.deleteSession(session).status, 404)
    }

    func testConfigurationPersistenceFailureIsReturnedToMCPCaller() async throws {
        let session = SurfaceSession(
            hardwareDevice: MCPFakeDevice(),
            configuration: .robotArmDemo(), saveHardwareMap: { _ in },
            saveConfiguration: { _ in
                throw MCPToolFailure("test store unavailable")
            }
        )
        let service = AgentControlService(
            session: session,
            permissions: MCPPermissions(configurationWrite: true, deviceControl: true)
        )
        service.onSelectSource = { session.selectSource($0) }
        let result = service.call("create_parameter", arguments: .object([
            "definition": try .encoded(ParameterDefinition(id: "x", name: "X"))
        ]))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.value.objectValue?["error"]?.stringValue?
            .contains(L10n.language == .chinese ? "内存" : "memory") == true)
        XCTAssertNotNil(session.engine.configuration.parameter("x"))
        XCTAssertEqual(session.lastConfigurationPersistenceError, "test store unavailable")
    }

    func testNestedSchemasRejectUnknownPropertiesAndFractionalControlIDs() async throws {
        let service = makeService()
        service.permissions.configurationWrite = true
        var definition = try JSONValue.encoded(ParameterDefinition(id: "x", name: "X")).objectValue!
        definition["unknown"] = .bool(true)
        XCTAssertTrue(service.call("create_parameter", arguments: .object(["definition": .object(definition)])).isError)
        let invalid: JSONValue = .object(["assignment": .object([
            "control": .object(["section": .string("encoder"), "row": .double(1.5), "index": .number(1)]),
            "target": .object(["parameter": .object(["_0": .string("arm.j1")])]),
            "buttonBehavior": .string("toggle"), "inverted": .bool(false)
        ])])
        XCTAssertTrue(service.call("assign_control", arguments: invalid).isError)
        XCTAssertNil(service.session.engine.configuration.parameter("x"))
        XCTAssertNil(service.session.engine.configuration.assignment(for: .encoder(row: 1, 1)))
    }

    func testStepAndNewAssignmentTargetsAreAvailableThroughGenericSchemas() async throws {
        let service = makeService()
        service.permissions.configurationWrite = true
        var definition = service.session.engine.configuration.parameter("arm.j1")!
        definition.step = 0.5
        XCTAssertFalse(service.call("update_parameter", arguments: .object(["definition": try .encoded(definition)]))
            .isError)
        let value = service.call(
            "set_parameter",
            arguments: .object(["id": .string("arm.j1"), "value": .double(90.26)])
        )
        XCTAssertEqual(value.value.objectValue?["value"], .double(90.5))
        XCTAssertEqual(value.value.objectValue?["clamped"], .bool(true))
        for target in [
            ControlTarget.stepParameter(id: "arm.j1", step: 0.5, wraps: false),
            .setParameter(id: "arm.j1", value: 45),
            .cycleParameter(id: "arm.j1", values: [-90, 0, 90])
        ] {
            XCTAssertFalse(service.call("assign_control", arguments: .object(["assignment": try .encoded(
                ControlAssignment(control: .userButton(1), target: target)
            )])).isError)
        }
        var raw = try JSONValue.encoded(definition).objectValue!
        raw["step"] = .null
        XCTAssertFalse(service.call("update_parameter", arguments: .object(["definition": .object(raw)])).isError)
        XCTAssertNil(service.session.engine.configuration.parameter("arm.j1")?.step)
    }

    func testV1ParameterMigrationProtectsEnableAndRoundTripsV2() async throws {
        let definition = ParameterDefinition(id: "arm.enabled", name: "Enable", minimum: 0, maximum: 1)
        var object = try JSONValue.encoded(definition).objectValue!
        object.removeValue(forKey: "agentWritable")
        object.removeValue(forKey: "externallyProtected")
        let decoded = try SurfaceConfigurationCodec.makeDecoder().decode(
            ParameterDefinition.self,
            from: JSONEncoder().encode(JSONValue.object(object))
        )
        XCTAssertFalse(decoded.agentWritable)
        let demo = SurfaceConfiguration.robotArmDemo()
        XCTAssertEqual(demo.version, SurfaceConfiguration.currentVersion)
        XCTAssertFalse(demo.parameter("arm.enabled")!.agentWritable)
        XCTAssertTrue(demo.parameter("arm.j1")!.agentWritable)
        XCTAssertEqual(try JSONValue.encoded(demo).decoded(SurfaceConfiguration.self), demo)
    }

    func testConfigurationPermissionCannotEscalateProtectedDefinitionsOrEnableValues() async throws {
        let service = makeService()
        service.permissions.configurationWrite = true
        let session = service.session
        let original = session.engine.configuration.parameter("arm.enabled")!
        var attacks: [ParameterDefinition] = []
        var changed = original; changed.agentWritable = true; attacks.append(changed)
        changed = original; changed.minimum = -1; changed.maximum = 0; attacks.append(changed)
        changed = original; changed.defaultValue = 1; attacks.append(changed)
        for attack in attacks {
            XCTAssertTrue(service.call("update_parameter", arguments: .object(["definition": try .encoded(attack)]))
                .isError)
            XCTAssertEqual(session.engine.configuration.parameter("arm.enabled"), original)
            XCTAssertEqual(session.engine.value(of: "arm.enabled"), 0)
        }
        XCTAssertTrue(service.call(
            "set_parameter",
            arguments: .object(["id": .string("arm.enabled"), "value": .number(1)])
        ).isError)
        var writable = session.engine.configuration.parameter("arm.j1")!
        writable.agentWritable = false
        XCTAssertTrue(service.call("update_parameter", arguments: .object(["definition": try .encoded(writable)]))
            .isError)
        try session.addParameter(.init(id: "readonly", name: "R", minimum: 0, maximum: 1, agentWritable: false))
        var readonly = session.engine.configuration.parameter("readonly")!
        readonly.name = "Changed"
        XCTAssertTrue(service.call("update_parameter", arguments: .object(["definition": try .encoded(readonly)]))
            .isError)
        try session.addParameter(.init(id: "custom.enable", name: "Enable", minimum: 0, maximum: 1, kind: .toggle))
        session.setOutputEnableParameter("custom.enable")
        let custom = session.engine.configuration.parameter("custom.enable")!
        XCTAssertTrue(service.call("update_parameter", arguments: .object(["definition": try .encoded(custom)]))
            .isError)
        XCTAssertTrue(service.call(
            "set_parameter",
            arguments: .object(["id": .string("custom.enable"), "value": .number(1)])
        ).isError)
        // Even a locally-created writable arm.enabled remains reserved to the operator.
        var local = original; local.agentWritable = true
        try session.updateParameter(local)
        XCTAssertTrue(service.call(
            "set_parameter",
            arguments: .object(["id": .string("arm.enabled"), "value": .number(1)])
        ).isError)
    }

    func testResetGroupResetsWritableParametersAndReportsProtectedSkips() async throws {
        let service = makeService()
        service.session.setParameter("arm.j1", to: 90)
        service.session.setParameter("arm.enabled", to: 1)
        let result = service.call(
            "reset_group",
            arguments: .object(["group": .string(SurfaceConfiguration.robotArmGroup)])
        )
        XCTAssertFalse(result.isError)
        let data = try XCTUnwrap(result.value.objectValue)
        let skipped = try XCTUnwrap(data["skipped"]?.arrayValue)
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?.objectValue?["id"], .string("arm.enabled"))
        XCTAssertEqual(data["results"]?.arrayValue?.count, 8)
        XCTAssertEqual(service.session.engine.value(of: "arm.j1"), 0)
        XCTAssertEqual(service.session.engine.value(of: "arm.enabled"), 1)
        try service.session.addParameter(.init(
            id: "only.readonly",
            name: "R",
            group: "Protected",
            minimum: 0,
            maximum: 1,
            agentWritable: false
        ))
        let protected = service.call("reset_group", arguments: .object(["group": .string("Protected")]))
        XCTAssertFalse(protected.isError)
        XCTAssertEqual(protected.value.objectValue?["results"]?.arrayValue?.count, 0)
        XCTAssertEqual(protected.value.objectValue?["skipped"]?.arrayValue?.count, 1)
        service.permissions.parameterWrite = false
        XCTAssertTrue(service.call(
            "reset_group",
            arguments: .object(["group": .string(SurfaceConfiguration.robotArmGroup)])
        ).isError)
    }
}
