import BCRFoundation
import BCRProviderApplication
import RobotPlugin
import ChassisPlugin
import RobotRemoteBinding
import ChassisRemoteBinding
import SimulationContracts
import SurfacePluginContracts
import Foundation
import XCTest

@MainActor
final class SharedSimulationCompatibilityTests: XCTestCase {
    private let access = ProviderAccess(write: true, robot: true, chassis: true, simulation: true)
    private func application() -> ProviderApplication {
        .init(configuration: .init(robot: true, chassis: true, clock: .manual), monotonic: { 0 })
    }

    func testHostUsesSharedStateAndOpaqueHostTokensWithInstanceIsolation() async throws {
        let first = application(), second = application()
        XCTAssertNotEqual(try first.robotState().metadata.generation, try second.robotState().metadata.generation)
        for app in [first, second] {
            _ = try app.executeRobot(
                .initialize(try app.robotState().metadata.generation, Array(repeating: 0, count: 6)),
                access: access
            )
        }
        let grant = try XCTUnwrap(first.executeRobot(
            .acquire(try first.robotState().metadata.generation, "fixture", 5),
            access: access
        ).control)
        XCTAssertNotNil(UUID(uuidString: grant.control_token))
        let proof = DeviceCommandProof(generation: grant.generation, token: grant.control_token, sequence: 1)
        XCTAssertThrowsError(try second.executeRobot(.enable(proof), access: access))
        _ = try first.executeRobot(.enable(proof), access: access)
        let plugin = try first.runtime.binding(ProviderApplication.robotInstanceID, as: RobotRemoteBinding.self).plugin
        XCTAssertEqual(plugin.simulator.control.lastCommandSequence, 1)
        XCTAssertTrue(plugin.simulator.control.enabled)
        let before = try JSONValue.encoded(first.robotState())
        XCTAssertEqual(before, try JSONValue.encoded(plugin.simulator.snapshot()))
        XCTAssertFalse(try before.jsonText.contains(grant.control_token))
        first.revokeControl(domain: "robot")
        XCTAssertFalse(try first.robotState().metadata.enabled)
        XCTAssertTrue(try second.robotState().stopped)
    }

    func testLegacyErrorCodeAndExactMessagesArePreservedAtApplicationBoundary() async throws {
        let app = application()
        XCTAssertThrowsError(try app.executeRobot(
            .acquire(try app.robotState().metadata.generation, "x", 1),
            access: access
        )) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("not_initialized", "Initialize the device first"))
        }
        XCTAssertThrowsError(try app.executeRobot(
            .initialize(try app.robotState().metadata.generation, [0]),
            access: access
        )) {
            XCTAssertEqual(
                $0 as? ProviderDomainError,
                .init("invalid_argument", "Finite joint vector with the model dimension is required")
            )
        }
        XCTAssertThrowsError(try app.advance(domain: "chassis", dt: .nan, access: access)) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("invalid_argument", "Invalid chassis time step"))
        }
        var control = DeviceControl(namespace: UUID().uuidString)
        XCTAssertThrowsError(try withLegacySimulationErrors { try control.initialize(expectedGeneration: "wrong") }) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("stale_generation", "The device generation changed"))
        }
    }

    func testCustomLegacyModelFieldsDecodeDirectlyToSharedTypedModel() async throws {
        let data = Data("""
        {"id":"custom","wheelbase_m":2,"track_m":0.8,"wheel_radius_m":0.2,
         "maximum_speed_m_s":0.7,"maximum_acceleration_m_s2":0.4,
         "maximum_steering_rad":0.3,"maximum_steering_rate_rad_s":0.5}
        """.utf8)
        let model = try JSONDecoder().decode(AckermannModel.self, from: data)
        let chassis = try ChassisSimulator(model: model, instanceID: UUID().uuidString)
        XCTAssertEqual(chassis.model.wheelbase_m, 2)
        XCTAssertEqual(chassis.model.maximum_speed_m_s, 0.7)
        XCTAssertEqual(chassis.snapshot().metadata.model_id, "custom")
        XCTAssertEqual(try JSONValue.encoded(model), try JSONValue.encoded(chassis.model))
    }

    func testSharedLifecycleStopBlocksHostWritesAndAdvanceFinishesBraking() async throws {
        let app = application()
        XCTAssertTrue(try app.runtime.binding(ProviderApplication.robotInstanceID, as: RobotRemoteBinding.self).plugin
            .acceptsWrites)
        _ = try app.executeRobot(
            .initialize(try app.robotState().metadata.generation, Array(repeating: 0, count: 6)),
            access: access
        )
        let grant = try XCTUnwrap(app.executeRobot(
            .acquire(try app.robotState().metadata.generation, "fixture", 5),
            access: access
        ).control)
        _ = try app.executeRobot(
            .enable(.init(generation: grant.generation, token: grant.control_token, sequence: 1)),
            access: access
        )
        _ = try app.executeRobot(
            .move(.init(generation: grant.generation, token: grant.control_token, sequence: 2), [1, 0, 0, 0, 0, 0], 1.5,
                  2),
            access: access
        )
        for _ in 0 ..< 7 { try app.advance(domain: "robot", dt: 0.1, access: access) }
        _ = try app.runtime.handle(ProviderApplication.robotInstanceID, input: .stop)
        XCTAssertFalse(try app.runtime.binding(ProviderApplication.robotInstanceID, as: RobotRemoteBinding.self).plugin
            .acceptsWrites)
        XCTAssertFalse(try app.robotState().stopped)
        XCTAssertThrowsError(try app.executeRobot(
            .initialize(try app.robotState().metadata.generation, [0, 0, 0, 0, 0, 0]),
            access: access
        )) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("stopped", "The plugin is stopped"))
        }
        for _ in 0 ..< 70 { try app.advance(domain: "robot", dt: 0.01, access: access) }
        XCTAssertTrue(try app.robotState().stopped)
        XCTAssertFalse(try app.runtime.binding(ProviderApplication.robotInstanceID, as: RobotRemoteBinding.self).plugin
            .snapshot().isStarted)
        XCTAssertThrowsError(try app.executeRobot(
            .acquire(try app.robotState().metadata.generation, "fixture", 1),
            access: access
        ))
        _ = try app.runtime.handle(ProviderApplication.chassisInstanceID, input: .stop)
        XCTAssertThrowsError(try app.executeChassis(
            .initialize(try app.chassisState().metadata.generation, [0, 0, 0]),
            access: access
        ))
        try app.advance(domain: "chassis", dt: 0.1, access: access)
        XCTAssertFalse(try app.runtime.binding(ProviderApplication.chassisInstanceID, as: ChassisRemoteBinding.self)
            .plugin.acceptsWrites)
    }
}
