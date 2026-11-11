import BCRChassisDomain
import BCRFoundation
import BCRRobotDomain
import BCRSimulationKernel
import Foundation
import XCTest

final class SharedSimulationCompatibilityTests: XCTestCase {
    func testLegacyWrapperUsesSharedStateAndOpaqueHostTokensWithInstanceIsolation() throws {
        var first = try RobotSimulator()
        var second = try RobotSimulator()
        XCTAssertNotEqual(first.control.generation, second.control.generation)
        try first.initialize(Array(repeating: 0, count: 6), generation: first.control.generation)
        try second.initialize(Array(repeating: 0, count: 6), generation: second.control.generation)
        let grant = try first.acquire(generation: first.control.generation, owner: "fixture", ttl: 5)
        XCTAssertNotNil(UUID(uuidString: grant.control_token))
        let proof = DeviceCommandProof(generation: grant.generation, token: grant.control_token, sequence: 1)
        XCTAssertThrowsError(try second.enable(proof))
        try first.enable(proof)
        XCTAssertEqual(first.plugin.simulator.control.lastCommandSequence, 1)
        XCTAssertTrue(first.plugin.simulator.control.enabled)
        let before = try JSONValue.encoded(first.snapshot())
        XCTAssertEqual(before, try JSONValue.encoded(first.plugin.simulator.snapshot()))
        XCTAssertFalse(try before.jsonText.contains(grant.control_token))
        first.plugin.simulator.revokeControl()
        XCTAssertFalse(first.snapshot().metadata.enabled)
        XCTAssertTrue(second.snapshot().stopped)
    }

    func testLegacyErrorCodeAndExactMessagesArePreservedAtTheFacade() throws {
        var robot = try RobotSimulator()
        XCTAssertThrowsError(try robot.acquire(generation: robot.control.generation, owner: "x", ttl: 1)) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("not_initialized", "Initialize the device first"))
        }
        XCTAssertThrowsError(try robot.initialize([0], generation: robot.control.generation)) {
            XCTAssertEqual($0 as? ProviderDomainError,
                           .init("invalid_argument", "Finite joint vector with the model dimension is required"))
        }
        var chassis = try ChassisSimulator()
        XCTAssertThrowsError(try chassis.advance(.nan)) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("invalid_argument", "Invalid chassis time step"))
        }
        var control = DeviceControl()
        XCTAssertThrowsError(try control.initialize(expectedGeneration: "wrong")) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("stale_generation", "The device generation changed"))
        }
    }

    func testCustomLegacyModelFieldsAreForwardedToSharedTypedModel() throws {
        let data = Data("""
        {"id":"custom","wheelbase_m":2,"track_m":0.8,"wheel_radius_m":0.2,
         "maximum_speed_m_s":0.7,"maximum_acceleration_m_s2":0.4,
         "maximum_steering_rad":0.3,"maximum_steering_rate_rad_s":0.5}
        """.utf8)
        let model = try JSONDecoder().decode(AckermannModel.self, from: data)
        let chassis = try ChassisSimulator(model: model)
        XCTAssertEqual(chassis.plugin.simulator.model.wheelbase_m, 2)
        XCTAssertEqual(chassis.plugin.simulator.model.maximum_speed_m_s, 0.7)
        XCTAssertEqual(chassis.snapshot().metadata.model_id, "custom")
        XCTAssertEqual(try JSONValue.encoded(model), try JSONValue.encoded(chassis.plugin.simulator.model))
    }

    func testSharedLifecycleStopBlocksLegacyWritesAndLegacyAdvanceFinishesBraking() throws {
        var robot = try RobotSimulator()
        XCTAssertTrue(robot.plugin.acceptsWrites)
        try robot.initialize(Array(repeating: 0, count: 6), generation: robot.control.generation)
        let grant = try robot.acquire(generation: robot.control.generation, owner: "fixture", ttl: 5)
        try robot.enable(.init(generation: grant.generation, token: grant.control_token, sequence: 1))
        try robot.move(.init(generation: grant.generation, token: grant.control_token, sequence: 2),
                       target: [1, 0, 0, 0, 0, 0], duration: 1.5, validFor: 2)
        for _ in 0 ..< 7 { try robot.advance(0.1) }
        _ = try robot.plugin.handle(.stop, at: 0)
        XCTAssertFalse(robot.plugin.acceptsWrites)
        XCTAssertFalse(robot.snapshot().stopped)
        XCTAssertThrowsError(try robot.initialize([0, 0, 0, 0, 0, 0], generation: robot.control.generation)) {
            XCTAssertEqual($0 as? ProviderDomainError, .init("stopped", "The plugin is stopped"))
        }
        for _ in 0 ..< 70 { try robot.advance(0.01) }
        XCTAssertTrue(robot.snapshot().stopped)
        XCTAssertFalse(robot.plugin.snapshot().isStarted)
        XCTAssertThrowsError(try robot.acquire(generation: robot.control.generation, owner: "fixture", ttl: 1))

        var chassis = try ChassisSimulator()
        _ = try chassis.plugin.handle(.stop, at: 0)
        XCTAssertThrowsError(try chassis.initialize([0, 0, 0], generation: chassis.control.generation))
        try chassis.advance(0.1)
        XCTAssertFalse(chassis.plugin.acceptsWrites)
    }
}
