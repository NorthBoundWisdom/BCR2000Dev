import BCRFoundation
import BCRSimulationKernel
import BCRRobotDomain
import BCRChassisDomain
import BCRSurfaceDomain
import BCRConfigurationAdapter
import Foundation
import XCTest

final class SimulationTests: XCTestCase {
    func proof(_ grant: DeviceControlGrant, _ sequence: Int) -> DeviceCommandProof {
        DeviceCommandProof(generation: grant.generation, token: grant.control_token, sequence: sequence)
    }

    func robot() throws -> (RobotSimulator, DeviceControlGrant) {
        var robot = try RobotSimulator()
        try robot.initialize(Array(repeating: 0, count: 6), generation: robot.control.generation)
        let grant = try robot.acquire(generation: robot.control.generation, owner: "fixture", ttl: 5)
        try robot.enable(proof(grant, 1))
        return (robot, grant)
    }

    func chassis() throws -> (ChassisSimulator, DeviceControlGrant) {
        var chassis = try ChassisSimulator()
        try chassis.initialize([0, 0, 0], generation: chassis.control.generation)
        let grant = try chassis.acquire(generation: chassis.control.generation, owner: "fixture", ttl: 5)
        try chassis.enable(proof(grant, 1))
        return (chassis, grant)
    }

    func testSurfaceDomainDefaultIsNeutralAndNeedsNoAgentBackend() {
        let config = SurfaceConfiguration.neutral()
        XCTAssertFalse(config.parameters.contains { $0.id.rawValue.hasPrefix("arm.") })
        XCTAssertFalse(config.assignments
            .contains { if case .agentPrimaryAction = $0.target { return true }; return false })
        XCTAssertTrue(config.parameters.allSatisfy(\.agentWritable))
    }

    func testLegacyProfileProtectionAndExplicitNewPolicyRemainSeparate() throws {
        let raw = #"{"version":1,"name":"legacy","parameters":[{"id":"arm.enabled","name":"Enable","minimum":0,"maximum":1,"agentWritable":true}],"assignments":[]}"#
        let old = try SurfaceConfigurationCodec.decode(Data(raw.utf8)).migrated()
        XCTAssertTrue(try XCTUnwrap(old.parameter("arm.enabled")).externallyProtected)
        XCTAssertEqual(old.version, 7)
        let ordinary = SurfaceConfiguration(name: "neutral", parameters: [.init(id: "arm.enabled", name: "Ordinary")])
        let decoded = try SurfaceConfigurationCodec.decode(JSONEncoder().encode(ordinary))
        XCTAssertFalse(try XCTUnwrap(decoded.parameter("arm.enabled")).externallyProtected)
    }

    func testUnknownInitialStateDoesNotBecomeZeroAndSourceIsSimulation() throws {
        var robot = try RobotSimulator()
        XCTAssertNil(robot.snapshot().actual)
        XCTAssertFalse(robot.snapshot().stopped)
        XCTAssertEqual(robot.snapshot().metadata.source, .simulation)
        XCTAssertThrowsError(try robot.acquire(generation: robot.control.generation, owner: "x", ttl: 1))
        XCTAssertNil(robot.snapshot().actual)
    }

    func testRobotTargetIsSeparateFromActualAndForwardPoseUsesActualJoints() throws {
        var (robot, grant) = try robot()
        let before = try XCTUnwrap(robot.snapshot().actual)
        let target = [1.0, 0, 0, 0, 0, 0]
        try robot.move(proof(grant, 2), target: target, duration: 1.5, validFor: 2)
        XCTAssertEqual(robot.snapshot().actual?.joints_rad, before.joints_rad)
        try robot.advance(0.1)
        let actual = try XCTUnwrap(robot.snapshot().actual)
        XCTAssertGreaterThan(actual.joints_rad[0], 0)
        XCTAssertLessThan(actual.joints_rad[0], 1)
        XCTAssertNotEqual(actual.base_from_tool_row_major_m, before.base_from_tool_row_major_m)
        XCTAssertEqual(actual.base_from_tool_row_major_m, robot.model.forward(actual.joints_rad))
        for _ in 0 ..< 15 { try robot.advance(0.1) }
        XCTAssertEqual(robot.snapshot().actual?.joints_rad, target)
        XCTAssertTrue(robot.snapshot().stopped)
    }

    func testRobotStopDeceleratesAndDoesNotResume() throws {
        var (robot, grant) = try robot()
        try robot.move(proof(grant, 2), target: [1, 0, 0, 0, 0, 0], duration: 1.5, validFor: 2)
        for _ in 0 ..< 7 { try robot.advance(0.1) }
        let initial = try XCTUnwrap(robot.snapshot().actual)
        try robot.stop(proof(grant, 3))
        XCTAssertEqual(robot.snapshot().actual?.joints_rad, initial.joints_rad)
        XCTAssertFalse(robot.snapshot().stopped)
        var previous = initial.joint_velocity_rad_s[0]
        for _ in 0 ..< 70 {
            try robot.advance(0.01)
            let next = try XCTUnwrap(robot.snapshot().actual).joint_velocity_rad_s[0]
            XCTAssertLessThanOrEqual(abs(next - previous), robot.model.maximum_acceleration_rad_s2 * 0.01 + 1e-10)
            previous = next
        }
        XCTAssertTrue(robot.snapshot().stopped)
        XCTAssertLessThan(try XCTUnwrap(robot.snapshot().actual).joints_rad[0], 1)
        let stopped = robot.snapshot().actual?.joints_rad
        try robot.advance(0.1)
        XCTAssertEqual(robot.snapshot().actual?.joints_rad, stopped)
    }

    func testInvalidRobotCommandsDoNotConsumeSequenceOrClamp() throws {
        var (robot, grant) = try robot()
        for target in [[4.0, 0, 0, 0, 0, 0], [Double.nan, 0, 0, 0, 0, 0], [0.0]] {
            XCTAssertThrowsError(try robot.move(proof(grant, 2), target: target, duration: 1.5, validFor: 2))
        }
        XCTAssertThrowsError(try robot.move(proof(grant, 2), target: [1, 0, 0, 0, 0, 0], duration: 0.01, validFor: 2))
        XCTAssertEqual(robot.control.lastCommandSequence, 1)
        XCTAssertFalse(robot.snapshot().motion_active)
    }

    func testControlGenerationTokenAndSequenceAreCheckedIndependently() throws {
        var (robot, grant) = try robot()
        XCTAssertThrowsError(try robot.enable(proof(grant, 1)))
        XCTAssertThrowsError(try robot.enable(.init(generation: grant.generation, token: "foreign", sequence: 2)))
        XCTAssertThrowsError(try robot.enable(.init(generation: "old", token: grant.control_token, sequence: 2)))
        try robot.reset(generation: robot.control.generation)
        XCTAssertNil(robot.snapshot().actual)
        XCTAssertThrowsError(try robot.enable(proof(grant, 2)))
    }

    func testChassisAccelerationBrakingAndCommandExpiryAreIntegrated() throws {
        var (chassis, grant) = try chassis()
        try chassis.drive(proof(grant, 2), speed: 0.5, steering: 0, validFor: 0.5)
        XCTAssertEqual(chassis.snapshot().actual?.speed_m_s, 0)
        for _ in 0 ..< 5 { try chassis.advance(0.1) }
        XCTAssertEqual(try XCTUnwrap(chassis.snapshot().actual).pose_m_rad[0], 0.125, accuracy: 1e-10)
        XCTAssertFalse(chassis.snapshot().stopped)
        for _ in 0 ..< 6 { try chassis.advance(0.1) }
        let actual = try XCTUnwrap(chassis.snapshot().actual)
        XCTAssertEqual(actual.speed_m_s, 0, accuracy: 1e-12)
        XCTAssertEqual(actual.pose_m_rad[0], 0.25, accuracy: 1e-10)
        XCTAssertTrue(chassis.snapshot().stopped)
    }

    func testAckermannSteeringIsNotYawRateAndCannotRotateInPlace() throws {
        var (chassis, grant) = try chassis()
        try chassis.drive(proof(grant, 2), speed: 0, steering: 0.3, validFor: 1)
        for _ in 0 ..< 4 { try chassis.advance(0.1) }
        XCTAssertEqual(chassis.snapshot().actual?.pose_m_rad, [0, 0, 0])
        try chassis.drive(proof(grant, 3), speed: 0.5, steering: 0.3, validFor: 1)
        for _ in 0 ..< 4 { try chassis.advance(0.1) }
        let actual = try XCTUnwrap(chassis.snapshot().actual)
        XCTAssertGreaterThan(actual.pose_m_rad[1], 0)
        XCTAssertEqual(
            actual.yaw_rate_rad_s,
            actual.speed_m_s * tan(actual.steering_angle_rad) / chassis.model.wheelbase_m,
            accuracy: 1e-12
        )
        XCTAssertNotEqual(actual.rear_wheel_velocity_rad_s[0], actual.rear_wheel_velocity_rad_s[1])
    }

    func testDomainResetClockAndFaultDoNotAffectAnotherDomain() throws {
        let (robot, _) = try robot()
        var (chassis, grant) = try chassis()
        let original = try JSONValue.encoded(robot.snapshot())
        try chassis.drive(proof(grant, 2), speed: 0.5, steering: 0.2, validFor: 0.3)
        try chassis.advance(0.1)
        try chassis.fault("telemetry_unavailable", generation: chassis.control.generation)
        XCTAssertNil(chassis.snapshot().actual)
        XCTAssertThrowsError(try chassis.enable(proof(grant, 3)))
        try chassis.reset(generation: chassis.control.generation)
        XCTAssertNil(chassis.snapshot().actual)
        XCTAssertEqual(try JSONValue.encoded(robot.snapshot()), original)
    }

    func testExpiredLeaseStopsAndRejectsOldControl() throws {
        var chassis = try ChassisSimulator()
        try chassis.initialize([0, 0, 0], generation: chassis.control.generation)
        let grant = try chassis.acquire(generation: chassis.control.generation, owner: "fixture", ttl: 0.2)
        try chassis.enable(proof(grant, 1))
        try chassis.drive(proof(grant, 2), speed: 0.5, steering: 0, validFor: 0.2)
        for _ in 0 ..< 6 { try chassis.advance(0.1) }
        XCTAssertTrue(chassis.snapshot().stopped)
        XCTAssertFalse(chassis.control.enabled)
        XCTAssertNil(chassis.snapshot().metadata.control_owner)
        XCTAssertThrowsError(try chassis.drive(proof(grant, 3), speed: 0.5, steering: 0, validFor: 0.1))
    }

    func testInvalidChassisValuesAndTimeAreRejectedWithoutMutation() throws {
        var (chassis, grant) = try chassis()
        XCTAssertThrowsError(try chassis.drive(proof(grant, 2), speed: 2, steering: 0, validFor: 1))
        XCTAssertThrowsError(try chassis.drive(proof(grant, 2), speed: 0, steering: .nan, validFor: 1))
        for dt in [0.0, -0.1, 0.2, .infinity] { XCTAssertThrowsError(try chassis.advance(dt)) }
        XCTAssertEqual(chassis.control.time, 0)
        XCTAssertEqual(chassis.control.lastCommandSequence, 1)
    }

    func testIndependentModelsHaveDeterministicMotionAndBoundedTrace() throws {
        var (left, a) = try chassis(); var (right, b) = try chassis()
        try left.drive(proof(a, 2), speed: 0.5, steering: 0.2, validFor: 1)
        try right.drive(proof(b, 2), speed: 0.5, steering: 0.2, validFor: 1)
        for _ in 0 ..< 600 { try left.advance(0.01); try right.advance(0.01) }
        XCTAssertEqual(left.snapshot().actual?.pose_m_rad, right.snapshot().actual?.pose_m_rad)
        XCTAssertEqual(left.trace.count, 512)
        XCTAssertGreaterThan(left.snapshot().trace_dropped, 0)
    }

    func testChassisStopBarrierPreventsReauthorizationAndRetargetUntilZeroSpeed() throws {
        var (chassis, grant) = try chassis()
        try chassis.drive(proof(grant, 2), speed: 0.8, steering: 0.3, validFor: 2)
        for _ in 0 ..< 5 { try chassis.advance(0.1) }
        try chassis.stop(proof(grant, 3))
        let stoppedSequence = chassis.control.lastCommandSequence
        XCTAssertFalse(chassis.snapshot().stopped)
        XCTAssertThrowsError(try chassis.enable(proof(grant, 4))) { XCTAssertEqual(
            ($0 as? ProviderDomainError)?.code,
            "busy"
        ) }
        XCTAssertThrowsError(try chassis.drive(proof(grant, 4), speed: 0.4, steering: -0.2, validFor: 1)) {
            XCTAssertEqual(
                ($0 as? ProviderDomainError)?.code,
                "busy"
            )
        }
        XCTAssertEqual(chassis.control.lastCommandSequence, stoppedSequence)
        for _ in 0 ..< 6 { try chassis.advance(0.1) }
        XCTAssertTrue(chassis.snapshot().stopped)
        try chassis.enable(proof(grant, 4))
        try chassis.drive(proof(grant, 5), speed: 0.4, steering: -0.2, validFor: 1)
        XCTAssertEqual(chassis.snapshot().target_speed_m_s, 0.4)
    }

    func testShortenedLeaseStopsAtExactBoundaryAndDoesNotContinueSteering() throws {
        var (chassis, grant) = try chassis()
        try chassis.drive(proof(grant, 2), speed: 0.8, steering: 0.5, validFor: 2)
        for _ in 0 ..< 3 { try chassis.advance(0.1) }
        try chassis.advance(0.01)
        try chassis.renew(proof(grant, 3), ttl: 0.1)
        try chassis.advance(0.1)
        let angleAtExpiry = try XCTUnwrap(chassis.snapshot().actual).steering_angle_rad
        XCTAssertFalse(chassis.control.enabled)
        let next = try chassis.acquire(generation: chassis.control.generation, owner: "next-owner", ttl: 2)
        XCTAssertThrowsError(try chassis.enable(proof(next, 1))) { XCTAssertEqual(
            ($0 as? ProviderDomainError)?.code,
            "busy"
        ) }
        for _ in 0 ..< 6 { try chassis.advance(0.1) }
        XCTAssertTrue(chassis.snapshot().stopped)
        XCTAssertEqual(try XCTUnwrap(chassis.snapshot().actual).steering_angle_rad, angleAtExpiry)
        try chassis.enable(proof(next, 1))
    }
}
