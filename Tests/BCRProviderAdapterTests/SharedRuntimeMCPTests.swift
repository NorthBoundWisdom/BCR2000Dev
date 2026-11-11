import AgentPlugin
import AgentRemoteBinding
import BCRFoundation
import BCRMCPAdapter
import BCRPluginRuntime
import BCRProviderApplication
import BCRProviderMCPAdapter
import Foundation
import RemoteToolContracts
import OutputRemoteBinding
import ParameterOutputPlugin
import SurfacePluginContracts
import XCTest

@MainActor
final class SharedRuntimeMCPTests: XCTestCase {
    private final class Clock { var time = 0.0 }
    private func host(clock: Clock, manual: Bool = true,
                      simulation: Bool = true) throws -> (ProviderApplication, MCPApplicationGateway)
    {
        let application = ProviderApplication(
            configuration: .init(robot: true, chassis: true, clock: manual ? .manual : .realtime),
            monotonic: { clock.time }
        )
        let service = MCPApplicationGateway(permissions: .init(
            parameterWrite: true,
            writesPerSecond: 10000,
            agentControl: true,
            robotControl: true,
            chassisControl: true,
            simulationControl: simulation
        ), includeAgent: false)
        try ProviderMCPModule.install(on: service, application: application)
        try ProviderMCPModule.installShared(on: service, application: application)
        return (application, service)
    }

    private func invoke(_ service: MCPApplicationGateway, _ name: String,
                        _ args: [String: JSONValue]) throws -> JSONValue
    {
        let result = service.call(name, arguments: .object(args))
        XCTAssertFalse(result.isError, "\(name): \(result.value)")
        return result.value
    }

    func testNewRemoteAndOldTypedCommandsMutateOneValueAndKeepRawAndLegacyEnvelopesSeparate() throws {
        let clock = Clock()
        let (application, service) = try host(clock: clock)
        let generation = try application.robotState().metadata.generation
        _ = try invoke(
            service,
            "surface_robot_initialize",
            ["instance_id": .string(ProviderApplication.robotInstanceID),
             "generation": .string(generation),
             "joints_rad": .array(Array(
                 repeating: .number(0),
                 count: 6
             ))]
        )
        XCTAssertTrue(try application.robotState().metadata.initialized)
        let grant = try invoke(
            service,
            "surface_robot_acquire",
            ["instance_id": .string(ProviderApplication.robotInstanceID),
             "generation": .string(application.robotState()
                 .metadata.generation), "owner": .string("fixture"),
             "ttl_s": .number(5)]
        )
        let token = try XCTUnwrap(grant.objectValue?["control_token"]?.stringValue)
        XCTAssertNotNil(UUID(uuidString: token))
        _ = try application.executeRobot(.enable(.init(generation: application.robotState().metadata.generation,
                                                       token: token, sequence: 1)), access: .init(
                write: true,
                robot: true,
                chassis: true,
                simulation: true
            ))
        var state = try invoke(
            service,
            "surface_robot_snapshot",
            ["instance_id": .string(ProviderApplication.robotInstanceID)]
        )
        XCTAssertEqual(state.objectValue?["metadata"]?.objectValue?["enabled"], .bool(true))
        XCTAssertFalse(try state.jsonText.contains(token))
        let maximum = try invoke(
            service,
            "surface_robot_enable",
            ["instance_id": .string(ProviderApplication.robotInstanceID),
             "generation": .string(application.robotState()
                 .metadata.generation),
             "control_token": .string(token),
             "sequence": .number(Int.max)]
        )
        XCTAssertEqual(maximum.objectValue?["metadata"]?.objectValue?["last_command_sequence"], .number(Int.max))
        XCTAssertEqual(try application.robotState().metadata.last_command_sequence, Int.max)
        state = maximum
        let newRPC = try service.call(
            "surface_robot_snapshot",
            arguments: .object(["instance_id": .string(ProviderApplication.robotInstanceID)])
        ).rpcValue
        XCTAssertEqual(newRPC.objectValue?["structuredContent"], state)
        XCTAssertNil(newRPC.objectValue?["structuredContent"]?.objectValue?["data"])
        let oldRPC = try service.call(
            "robot_state",
            arguments: .object(["schema_version": .number(1), "device_id": .string("robot.reference")])
        ).rpcValue
        XCTAssertNotNil(oldRPC.objectValue?["structuredContent"]?.objectValue?["data"])
        let trace = try invoke(
            service,
            "surface_robot_trace",
            ["instance_id": .string(ProviderApplication.robotInstanceID)]
        )
        XCTAssertNotNil(trace.objectValue?["samples"]?.arrayValue)
    }

    func testSimulationAdministrationAndClockModeCannotBeBypassedByNewTools() throws {
        let clock = Clock()
        let (application, service) = try host(clock: clock, simulation: false)
        for (kind, id, generation) in [
            ("robot", ProviderApplication.robotInstanceID, try application.robotState().metadata.generation),
            ("chassis", ProviderApplication.chassisInstanceID, try application.chassisState().metadata.generation)
        ] {
            let advance = service.call(
                "surface_\(kind)_advance",
                arguments: .object(["instance_id": .string(id), "dt_s": .double(0.1)])
            )
            XCTAssertTrue(advance.isError)
            XCTAssertEqual(advance.value.objectValue?["code"], .string("permissionDenied"))
            let reset = service.call(
                "surface_\(kind)_reset",
                arguments: .object(["instance_id": .string(id), "generation": .string(generation)])
            )
            XCTAssertTrue(reset.isError)
            XCTAssertEqual(reset.value.objectValue?["code"], .string("permissionDenied"))
        }
        XCTAssertEqual(try application.robotState().metadata.simulated_time_s, 0)
        let oldAdvance = service.call(
            "simulation_advance",
            arguments: .object(["schema_version": .number(1), "domain": .string("robot"), "dt_s": .double(0.1)])
        )
        XCTAssertTrue(oldAdvance.isError)
        XCTAssertEqual(oldAdvance.value.objectValue?["error"]?.objectValue?["code"], .string("permission_denied"))
        XCTAssertEqual(
            oldAdvance.value.objectValue?["error"]?.objectValue?["message"],
            .string("Simulation clock permission is required")
        )
        let (_, realtime) = try host(clock: clock, manual: false)
        let denied = realtime.call(
            "surface_robot_advance",
            arguments: .object(["instance_id": .string(ProviderApplication.robotInstanceID), "dt_s": .double(0.1)])
        )
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(denied.value.objectValue?["code"], .string("permissionDenied"))
    }

    func testOutputEnableCannotForgeAuthorityAndSharedReadsDoNotAppendEvents() throws {
        let clock = Clock()
        let (application, service) = try host(clock: clock)
        try application.runtime.install([OutputRemoteBinding(
            instanceID: "output.test",
            plugin: try ParameterOutputPlugin(
                limits: [.init(id: "axis", minimum: 0, maximum: 1, maximumChange: 0.1, maximumVelocity: 1)]
            )
        )])
        XCTAssertTrue(service.toolDefinitions
            .contains { $0.objectValue?["name"] == .string("surface_output_snapshot") })
        let before = try application.runtime.call(
            "surface_events",
            arguments: .object([
                "epoch": .string(application.runtime.epoch),
                "after": .string("0"),
                "limit": .number(256)
            ])
        )
        let enable = service.call("surface_output_enable", arguments: .object(["instance_id": .string("output.test")]))
        XCTAssertTrue(enable.isError)
        XCTAssertEqual(enable.value.objectValue?["code"], .string("permissionDenied"))
        let forged = service.call(
            "surface_output_enable",
            arguments: .object(["instance_id": .string("output.test"), "permitsOutputEnable": .bool(true)])
        )
        XCTAssertTrue(forged.isError)
        XCTAssertEqual(forged.value.objectValue?["code"], .string("invalidParameter"))
        let afterFailures = try application.runtime.call("surface_events", arguments: .object([
            "epoch": .string(application.runtime.epoch), "after": .string("0"), "limit": .number(256)
        ]))
        XCTAssertEqual(before, afterFailures)
        service.permissions.parameterWrite = false // Legitimately revokes old simulator control.
        let beforeRead = try application.runtime.call("surface_events", arguments: .object([
            "epoch": .string(application.runtime.epoch), "after": .string("0"), "limit": .number(256)
        ]))
        let read = service.call("surface_output_snapshot", arguments: .object(["instance_id": .string("output.test")]))
        XCTAssertFalse(read.isError)
        let after = try application.runtime.call(
            "surface_events",
            arguments: .object([
                "epoch": .string(application.runtime.epoch),
                "after": .string("0"),
                "limit": .number(256)
            ])
        )
        XCTAssertEqual(beforeRead, after)
        XCTAssertEqual(read.value.objectValue?["requested_enabled"], .bool(false))
    }

    func testUnknownAndMissingRoutesMatchSharedErrorsWithoutMutatingJournal() throws {
        let clock = Clock()
        let (application, service) = try host(clock: clock)
        var reference = try RemoteRegistry(epoch: "reference")
        let before = try application.runtime.call(
            "surface_events",
            arguments: .object([
                "epoch": .string(application.runtime.epoch),
                "after": .string("0"),
                "limit": .number(256)
            ])
        )
        let cases: [JSONValue] = [
            .object([:]),
            .object(["instance_id": .number(1)]),
            .object(["instance_id": .string("missing")])
        ]
        for args in cases {
            let result = service.call("surface_robot_initialize", arguments: args)
            XCTAssertTrue(result.isError)
            do {
                _ = try reference.call("surface_robot_initialize", arguments: args, context: .init(time: 0)); XCTFail()
            } catch let error as RemoteFailure { XCTAssertEqual(result.value.objectValue?["code"], .string(error.code))
            }
        }
        let after = try application.runtime.call(
            "surface_events",
            arguments: .object([
                "epoch": .string(application.runtime.epoch),
                "after": .string("0"),
                "limit": .number(256)
            ])
        )
        XCTAssertEqual(before, after)
    }

    func testRegressedAndNonfiniteClockFaultsRemainVisibleAndDoNotCrashOrAcceptOrdinaryWrites() throws {
        let clock = Clock()
        let (application, _) = try host(clock: clock, manual: false)
        let access = ProviderAccess(write: true, robot: true, chassis: true, simulation: true)
        _ = try application.executeRobot(
            .initialize(application.robotState().metadata.generation, Array(repeating: 0, count: 6)),
            access: access
        )
        let grant = try XCTUnwrap(application.executeRobot(
            .acquire(application.robotState().metadata.generation, "fixture", 5),
            access: access
        ).control)
        _ = try application.executeRobot(
            .enable(.init(generation: grant.generation, token: grant.control_token, sequence: 1)),
            access: access
        )
        clock.time = 1; application.tick()
        _ = try application.runtime.handle(ProviderApplication.chassisInstanceID, input: .stop)
        for time in [0.5, 0.6, 0.7, Double.nan, 0.8] {
            clock.time = time
            application.tick()
            let state = try application.robotState()
            XCTAssertEqual(state.metadata.fault, "host_clock_gap")
            XCTAssertFalse(state.metadata.enabled)
            XCTAssertNil(state.metadata.control_owner)
            XCTAssertEqual(state.metadata.simulated_time_s, 1, accuracy: 1e-10)
            XCTAssertNil(application.lastSafetyFailure)
            XCTAssertThrowsError(try application.runtime.call("surface_robot_reset", arguments: .object([
                "instance_id": .string(ProviderApplication.robotInstanceID),
                "generation": .string(state.metadata.generation)
            ])))
        }
        clock.time = 1.1; application.tick()
        XCTAssertEqual(try application.robotState().metadata.simulated_time_s, 1.1, accuracy: 1e-10)
        XCTAssertEqual(try application.chassisState().metadata.fault, "host_clock_gap")
        XCTAssertFalse(try XCTUnwrap(application.runtime.snapshot(ProviderApplication.chassisInstanceID)).isStarted)
        let events = try application.runtime.call(
            "surface_events",
            arguments: .object([
                "epoch": .string(application.runtime.epoch),
                "after": .string("0"),
                "limit": .number(256)
            ])
        )
        let records = try XCTUnwrap(events.objectValue?["events"]?.arrayValue)
        XCTAssertTrue(records
            .contains { $0.objectValue?["event"]?.objectValue?["fields"]?.objectValue?["clock"] == .string("regressed")
            })
        XCTAssertTrue(records
            .contains { $0.objectValue?["event"]?.objectValue?["fields"]?.objectValue?["clock"] == .string("nonfinite")
            })
    }
}
