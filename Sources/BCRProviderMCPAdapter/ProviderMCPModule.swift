import BCRFoundation
import BCRMCPAdapter
import BCRSurfaceDomain
import BCRProviderApplication
import BCRRobotDomain
import BCRChassisDomain
import Foundation

@MainActor
public enum ProviderMCPModule {
    /// Explicit transport authorization at the composition boundary, never inside a plugin.
    public static func installShared(on service: AgentControlService, application: ProviderApplication) throws {
        let manual = application.configuration.clock == .manual
        try SharedPluginMCPModule.install(on: service, runtime: application.runtime, policies: [
            "agent": { permission, _ in permission.parameterWrite && permission.agentControl },
            "robot": { permission, name in
                guard permission.parameterWrite else { return false }
                if name == "surface_robot_advance" { return manual && permission.simulationControl }
                if name == "surface_robot_reset" { return permission.robotControl && permission.simulationControl }
                return permission.robotControl
            },
            "chassis": { permission, name in
                guard permission.parameterWrite else { return false }
                if name == "surface_chassis_advance" { return manual && permission.simulationControl }
                if name == "surface_chassis_reset" { return permission.chassisControl && permission.simulationControl }
                return permission.chassisControl
            },
            "output": { permission, _ in permission.parameterWrite }
        ])
    }

    private static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    private static func tool(_ name: String, schema: JSONValue, readonly: Bool) -> JSONValue {
        let response: String
        switch name {
        case "provider_capabilities": response = "capabilities"
        case "provider_state", "simulation_advance": response = "providerState"
        case "provider_contract": response = "schemaDocument"
        case "console_events": response = "eventBatch"
        case "console_mock_input": response = "mockInputReply"
        case "console_diagnostics": response = "diagnosticReply"
        case "robot_state": response = "robotSnapshot"
        case "robot_command": response = "robotCommandReply"
        case "robot_trace": response = "robotTrace"
        case "chassis_state": response = "chassisSnapshot"
        case "chassis_command": response = "chassisCommandReply"
        case "chassis_trace": response = "chassisTrace"
        default: preconditionFailure("Missing provider response contract")
        }
        let output = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["data": .object(["$ref": .string("#/$defs/" + response)])]),
            "required": .array([.string("data")]), "additionalProperties": .bool(false),
            "$defs": ProviderContractSchema.document.objectValue!["$defs"]!
        ])
        return .object(["name": .string(name), "description": .string("BCR provider contract 1.0: " + name),
                        "inputSchema": schema,
                        "outputSchema": output,
                        "annotations": .object(["readOnlyHint": .bool(readonly), "openWorldHint": .bool(false)])])
    }

    public static func tools(configuration: ProviderConfiguration) -> [JSONValue] {
        var tools = [tool("provider_capabilities", schema: object(), readonly: true),
                     tool("provider_state", schema: object(), readonly: true),
                     tool("provider_contract", schema: object(), readonly: true),
                     tool(
                         "console_events",
                         schema: ProviderContractSchema.definition("consoleEventsRequest"),
                         readonly: true
                     ),
                     tool("console_mock_input", schema: object([
                         "control": MCPToolCatalog.inputSchema(for: "begin_control_learn").objectValue!["properties"]!
                             .objectValue!["control"]!,
                         "operation": .object(["enum": .array(["turn", "press", "release"].map(JSONValue.string))]),
                         "delta": .object([
                             "type": .string("integer"),
                             "minimum": .number(-127),
                             "maximum": .number(127)
                         ])
                     ], required: ["control", "operation"]), readonly: false),
                     tool("console_diagnostics", schema: object([
                         "operation": .object(["enum": .array(["begin", "end", "abort"].map(JSONValue.string))]),
                         "token": .object(["type": .string("string")])
                     ], required: ["operation"]), readonly: false)]
        if configuration.robot {
            tools += [tool("robot_command", schema: ProviderContractSchema.definition("robotCommand"), readonly: false),
                      tool(
                          "robot_state",
                          schema: ProviderContractSchema.definition("robotStateRequest"),
                          readonly: true
                      ),
                      tool(
                          "robot_trace",
                          schema: ProviderContractSchema.definition("robotStateRequest"),
                          readonly: true
                      )]
        }
        if configuration.chassis {
            tools += [
                tool("chassis_command", schema: ProviderContractSchema.definition("chassisCommand"), readonly: false),
                tool("chassis_state", schema: ProviderContractSchema.definition("chassisStateRequest"), readonly: true),
                tool("chassis_trace", schema: ProviderContractSchema.definition("chassisStateRequest"), readonly: true)
            ]
        }
        if configuration.robot || configuration.chassis {
            tools.append(tool(
                "simulation_advance",
                schema: ProviderContractSchema.definition("simulationAdvance"),
                readonly: false
            ))
        }
        return tools
    }

    public static func install(on service: AgentControlService, application: ProviderApplication,
                               enableSurfaceControl: Bool = false,
                               surfaceInstanceID: String? = nil,
                               surfacePermissions: BCRSurfaceControlAdapter.Permissions = .init(),
                               surfaceMomentaryHoldsOnly: Bool = false) throws
    {
        try service.registerModule(
            id: "bcr.provider.1.0",
            tools: tools(configuration: application.configuration)
                .filter {
                    service
                        .surfaceSession != nil ||
                        !($0.objectValue?["name"]?.stringValue?.hasPrefix("console_") ?? false)
                }
        ) { [weak service, application] name, args in
            guard let service else { throw ProviderDomainError("unavailable", "Provider host stopped") }
            let permissions = service.permissions
            let access = ProviderAccess(write: permissions.parameterWrite, robot: permissions.robotControl,
                                        chassis: permissions.chassisControl, simulation: permissions.simulationControl)
            switch name {
            case "provider_capabilities": return capabilities(service: service, application: application)
            case "provider_state": return application.state()
            case "provider_contract": return ProviderContractSchema.document
            case "console_events":
                return try service.session.inputEvents.read(generation: args["generation"]?.stringValue,
                                                            after: args["after_sequence"]?.roundedIntValue ?? 0,
                                                            limit: args["limit"]?.roundedIntValue ?? 256)
            case "console_mock_input":
                // With the optional surface contract installed, all simulated input must pass its
                // permission and CAS fences. Without it, Provider 1.0 behavior is unchanged.
                try ProviderValidation.require(
                    !enableSurfaceControl,
                    "permission_denied",
                    "Surface control is enabled; use surface_control_input for simulated input"
                )
                let session = service.session
                try ProviderValidation.require(
                    permissions.parameterWrite && permissions.deviceControl,
                    "permission_denied",
                    "Explicit Mock-device control permission is required"
                )
                try ProviderValidation.require(
                    session.source == .mock,
                    "unsupported",
                    "Synthetic input is not permitted on a hardware source"
                )
                let control = try args["control"]!.decoded(BCRControlID.self)
                guard let target = session.engine.configuration.assignment(for: control)?.target,
                      case let .parameter(id) = target, let parameter = session.engine.configuration.parameter(id),
                      parameter.agentWritable, !session.isMCPProtectedParameter(id)
                else { throw ProviderDomainError(
                    "permission_denied",
                    "Mock input cannot bypass protected parameters or invoke another domain"
                ) }
                switch try text(args, "operation") {
                case "turn":
                    try ProviderValidation.require(
                        control.isContinuous && args["delta"]?.roundedIntValue != nil,
                        "invalid_argument",
                        "Turning requires a continuous control and integer delta"
                    )
                    session.withWriteOrigin(.agent) { session.turn(control, by: args["delta"]!.roundedIntValue!) }
                case "press", "release":
                    try ProviderValidation.require(
                        !control.isContinuous,
                        "invalid_argument",
                        "Button input requires a button"
                    )
                    session.withWriteOrigin(.agent) {
                        if args["operation"] == .string("press") { session.press(control) }
                        else { session.release(control) }
                    }
                default: throw ProviderDomainError("unsupported", "Unknown Mock input operation")
                }
                return .object([
                    "source": .string("mock"),
                    "origin": .string("agent"),
                    "generation": .string(session.inputEvents.generation)
                ])
            case "console_diagnostics":
                try ProviderValidation.require(
                    permissions.parameterWrite && permissions.deviceControl,
                    "permission_denied",
                    "Device-control permission is required for diagnostics"
                )
                switch try text(args, "operation") {
                case "begin": return .object([
                        "token": .string(try service.session.beginDiagnosticReadback()),
                        "active": .bool(true)
                    ])
                case "end": try service.session.endDiagnosticReadback(token: text(args, "token"))
                case "abort": service.session.abortDiagnosticReadback()
                default: throw ProviderDomainError("unsupported", "Unsupported diagnostic operation")
                }
                return .object(["active": .bool(false)])
            case "robot_state": return try .encoded(application.robotState())
            case "chassis_state": return try .encoded(application.chassisState())
            case "robot_trace":
                let state = try application.robotState(), samples = try application.robotTrace()
                return .object(["metadata": try .encoded(state.metadata), "samples": try .encoded(samples),
                                "dropped": .number(Int(state.trace_dropped)),
                                "earliest_sequence": .number(Int(samples.first?.sequence ?? 0)),
                                "latest_sequence": .number(Int(samples.last?.sequence ?? 0))])
            case "chassis_trace":
                let state = try application.chassisState(), samples = try application.chassisTrace()
                return .object(["metadata": try .encoded(state.metadata), "samples": try .encoded(samples),
                                "dropped": .number(Int(state.trace_dropped)),
                                "earliest_sequence": .number(Int(samples.first?.sequence ?? 0)),
                                "latest_sequence": .number(Int(samples.last?.sequence ?? 0))])
            case "robot_command": return try .encoded(application.executeRobot(robotOperation(args), access: access))
            case "chassis_command": return try .encoded(application.executeChassis(
                    chassisOperation(args),
                    access: access
                ))
            case "simulation_advance":
                try application.advance(domain: text(args, "domain"), dt: number(args, "dt_s"), access: access)
                return application.state()
            default: throw ProviderDomainError("unsupported", "Unsupported provider capability")
            }
        }
        _ = service.observePermissions { [weak application] old, new in
            if old.parameterWrite && old
                .robotControl &&
                !(new.parameterWrite && new.robotControl) { application?.revokeControl(domain: "robot") }
            if old.parameterWrite && old
                .chassisControl &&
                !(new.parameterWrite && new.chassisControl) { application?.revokeControl(domain: "chassis") }
        }
        if enableSurfaceControl {
            try SurfaceControlMCPModule.install(on: service, instanceID: surfaceInstanceID ?? application.providerID,
                                                permissions: surfacePermissions,
                                                momentaryHoldsOnly: surfaceMomentaryHoldsOnly)
        }
    }

    public static func capabilities(service: AgentControlService, application: ProviderApplication) -> JSONValue {
        let surface = service.surfaceSession
        return .object([
            "contract_version": .string("1.0"), "schema_version": .number(1),
            "provider_id": .string(application.providerID),
            "resources": .string(ProviderResources.origin),
            "transport": .array(["mcp_http", "sse"].map(JSONValue.string)), "network": .string("ipv4_loopback_only"),
            "clock": .string(application.configuration.clock.rawValue),
            "console": .object([
                "enabled": .bool(surface != nil),
                "source": surface.map { .string($0.source.rawValue) } ?? .null,
                "generation": surface.map { .string($0.inputEvents.generation) } ?? .null,
                "diagnostic_readback": .bool(surface?.diagnosticReadbackActive ?? false),
                "input_event_capacity": .number(512),
                "supported_encodings": .array(["absolute_cc_7bit", "relative1", "relative2", "nrpn14"]
                    .map(JSONValue.string)),
                "hardware_qualification": .string("requires_explicit_device_validation"),
                "hardware_unqualified_encoding": .array(["relative1", "relative2", "nrpn14"].map(JSONValue.string))
            ]),
            "robot": .object(["enabled": .bool(application.configuration.robot), "source": .string("simulation"),
                              "frame_id": .string("reference_robot_base_v1"),
                              "coordinate_convention": .string("right_handed_X_forward_Y_left_Z_up"),
                              "transform_layout": .string("row_major_column_vector"),
                              "device_id": .string("robot.reference"), "model": try! .encoded(RobotModel.reference),
                              "units": .object(["joints": .string("rad"), "translation": .string("m")]),
                              "frame": .string("right_handed_base_Z_up; row-major transform acting on column vectors"),
                              "unsupported": .array([
                                  "inverse_kinematics",
                                  "cartesian_motion",
                                  "vendor_program",
                                  "collision_qualification",
                                  "real_hardware"
                              ].map(JSONValue.string))]),
            "chassis": .object(["enabled": .bool(application.configuration.chassis), "source": .string("simulation"),
                                "frame_id": .string("chassis_x_forward_y_left_z_up_v1"),
                                "coordinate_convention": .string("right_handed_X_forward_Y_left_Z_up"),
                                "pose_layout": .string("x_m_y_m_yaw_rad_ccw"),
                                "device_id": .string("chassis.reference"),
                                "model": try! .encoded(AckermannModel.reference),
                                "units": .object(["speed": .string("m/s"), "steering": .string("rad")]),
                                "frame": .string("X_forward_Y_left_Z_up; positive_yaw_counterclockwise"),
                                "unsupported": .array([
                                    "lateral_motion",
                                    "in_place_rotation",
                                    "real_can",
                                    "real_hardware"
                                ].map(JSONValue.string))]),
            "permissions": try! .encoded(service.permissions),
            "agent": .object([
                "enabled": .bool(service.onReadAgents != nil),
                "control_permission": .bool(service.permissions.parameterWrite && service.permissions.agentControl)
            ]),
            "event_limits": .object([
                "journal_capacity": .number(512),
                "read_limit": .number(256),
                "sse_delta_bytes": .number(65536)
            ]),
            "requirements": .object([
                "max_control_ttl_s": .double(5),
                "max_manual_step_s": .double(0.1),
                "normal_observation_budget_s": .double(2)
            ])
        ])
    }

    private static func text(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty, value.utf8.count <= 128 else {
            throw ProviderDomainError("invalid_argument", "A bounded string field is missing")
        }
        return value
    }

    private static func number(_ args: [String: JSONValue], _ key: String) throws -> Double {
        guard let value = args[key]?.finiteNumber else { throw ProviderDomainError(
            "invalid_argument",
            "A finite numeric field is missing"
        ) }; return value
    }

    private static func vector(_ args: [String: JSONValue], _ key: String) throws -> [Double] {
        guard let values = args[key]?.arrayValue, values.count <= 12 else { throw ProviderDomainError(
            "invalid_argument",
            "A bounded numeric vector is required"
        ) }
        return try values.map { value in
            guard let number = value.finiteNumber else { throw ProviderDomainError(
                "invalid_argument",
                "Finite vector values are required"
            ) }; return number
        }
    }

    private static func proof(_ args: [String: JSONValue]) throws -> DeviceCommandProof {
        guard let sequence = args["command_sequence"]?.roundedIntValue else { throw ProviderDomainError(
            "invalid_argument",
            "An integer command sequence is required"
        ) }
        return DeviceCommandProof(
            generation: try text(args, "generation"),
            token: try text(args, "control_token"),
            sequence: sequence
        )
    }

    private static func robotOperation(_ args: [String: JSONValue]) throws -> RobotOperation {
        let generation = try text(args, "generation")
        switch try text(args, "operation") {
        case "initialize": return .initialize(generation, try vector(args, "initial_joints_rad"))
        case "acquire": return .acquire(generation, try text(args, "owner"), try number(args, "ttl_s"))
        case "enable": return .enable(try proof(args))
        case "stop": return .stop(try proof(args))
        case "disable": return .disable(try proof(args))
        case "release": return .release(try proof(args))
        case "renew": return .renew(try proof(args), try number(args, "ttl_s"))
        case "move_joints": return .move(
                try proof(args),
                try vector(args, "target_joints_rad"),
                try number(args, "duration_s"),
                try number(args, "valid_for_s")
            )
        case "reset": return .reset(generation)
        case "fault": return .fault(generation, try text(args, "fault_code"))
        case "clear_fault": return .clearFault(generation)
        default: throw ProviderDomainError("unsupported", "Unsupported robot operation")
        }
    }

    private static func chassisOperation(_ args: [String: JSONValue]) throws -> ChassisOperation {
        let generation = try text(args, "generation")
        switch try text(args, "operation") {
        case "initialize": return .initialize(generation, try vector(args, "initial_pose_m_rad"))
        case "acquire": return .acquire(generation, try text(args, "owner"), try number(args, "ttl_s"))
        case "enable": return .enable(try proof(args))
        case "stop": return .stop(try proof(args))
        case "disable": return .disable(try proof(args))
        case "release": return .release(try proof(args))
        case "renew": return .renew(try proof(args), try number(args, "ttl_s"))
        case "drive": return .drive(
                try proof(args),
                try number(args, "speed_m_s"),
                try number(args, "steering_angle_rad"),
                try number(args, "valid_for_s")
            )
        case "reset": return .reset(generation)
        case "fault": return .fault(generation, try text(args, "fault_code"))
        case "clear_fault": return .clearFault(generation)
        default: throw ProviderDomainError("unsupported", "Unsupported chassis operation")
        }
    }
}
