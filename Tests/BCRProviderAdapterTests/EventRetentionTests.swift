import AgentPlugin
import AgentRemoteBinding
import BCRFoundation
import BCRPluginRuntime
import BCRProviderApplication
import Foundation
import RemoteToolContracts
import SurfacePluginContracts
import XCTest

@MainActor
final class EventRetentionTests: XCTestCase {
    private final class Clock { var value = 0.0; var notifications = 0 }
    private let access = ProviderAccess(write: true, robot: true, chassis: true, simulation: true)
    private func events(_ owner: BCRPluginRuntime) throws -> JSONValue {
        try owner.call(
            "surface_events",
            arguments: .object(["epoch": .string(owner.epoch), "after": .string("0"), "limit": .number(1024)])
        )
    }

    func testTenThousandIdleTicksPreserveEarlyEventsAndLegacyTimeRevisionTraceAndSSE() throws {
        let clock = Clock()
        let owner = try BCRPluginRuntime(clock: { clock.value }, epoch: "retention")
        try owner.install([AgentRemoteBinding(instanceID: AgentRemoteBinding.defaultInstanceID,
                                              plugin: AgentPlugin(approvalPolicy: .localOrigins, at: 0))])
        _ = try owner.call("surface_agent_primary", arguments: .object([
            "instance_id": .string(AgentRemoteBinding.defaultInstanceID), "slot": .number(1)
        ]))
        let application = ProviderApplication(configuration: .init(robot: true, chassis: true), runtime: owner)
        clock.value = 3; application.tick() // Keep an early meaningful safety fault in the inventory.
        _ = try application.executeRobot(.reset(application.robotState().metadata.generation), access: access)
        _ = try application.executeRobot(
            .initialize(application.robotState().metadata.generation, Array(repeating: 0, count: 6)),
            access: access
        )
        _ = try application.executeChassis(.reset(application.chassisState().metadata.generation), access: access)
        _ = try application.executeChassis(
            .initialize(application.chassisState().metadata.generation, [0, 0, 0]),
            access: access
        )
        let before = try events(owner)
        let oldRobot = try application.robotState(), oldChassis = try application.chassisState()
        let oldSSE = application.events.sequence
        let observer = owner.observe { _ in clock.notifications += 1 }
        defer { owner.removeObserver(observer) }
        for index in 1 ... 10_000 {
            clock.value = 3 + Double(index) * 0.02
            application.tick()
        }
        XCTAssertEqual(try events(owner), before)
        XCTAssertEqual(clock.notifications, 0, "Silent state commits must not broadcast idle work")
        let robot = try application.robotState(), chassis = try application.chassisState()
        XCTAssertEqual(robot.metadata.simulated_time_s - oldRobot.metadata.simulated_time_s, 200, accuracy: 1e-8)
        XCTAssertEqual(chassis.metadata.simulated_time_s - oldChassis.metadata.simulated_time_s, 200, accuracy: 1e-8)
        XCTAssertEqual(robot.metadata.sequence, oldRobot.metadata.sequence + 10_000)
        XCTAssertEqual(chassis.metadata.sequence, oldChassis.metadata.sequence + 10_000)
        XCTAssertEqual(
            application.events.sequence,
            oldSSE + 10_000,
            "Provider 1.0 SSE cadence is a separate compatibility contract"
        )
        XCTAssertEqual(try application.robotTrace().count, 512)
        XCTAssertEqual(try application.chassisTrace().count, 512)
        XCTAssertGreaterThan(robot.trace_dropped, 9000)
        let records = try XCTUnwrap(before.objectValue?["events"]?.arrayValue)
        XCTAssertTrue(records
            .contains { $0.objectValue?["event"]?.objectValue?["code"] == .string("surface_agent_primary") })
        XCTAssertTrue(records
            .contains { $0.objectValue?["event"]?.objectValue?["code"] == .string("host.safety.robot.fault") })
    }

    func testContinuousMotionIsThrottledButStateAndCriticalFinalTransitionStayCurrent() throws {
        let clock = Clock()
        let application = ProviderApplication(
            configuration: .init(robot: true, clock: .manual),
            monotonic: { clock.value }
        )
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
        _ = try application.executeRobot(
            .move(.init(generation: grant.generation, token: grant.control_token, sequence: 2),
                  [1, 0, 0, 0, 0, 0], 1.5, 2),
            access: access
        )
        let before = try events(application.runtime)
        let base = try XCTUnwrap(before.objectValue?["latestSequence"]?.exactIntValue)
        var previous = 0.0
        for index in 1 ... 80 {
            clock.value = Double(index) * 0.02
            try application.advance(domain: "robot", dt: 0.02, access: access)
            let state = try application.robotState()
            let actual = try XCTUnwrap(state.actual?.joints_rad.first)
            XCTAssertGreaterThanOrEqual(actual, previous)
            previous = actual
            XCTAssertEqual(state.metadata.simulated_time_s, clock.value, accuracy: 1e-9)
        }
        let final = try application.robotState()
        XCTAssertTrue(final.stopped)
        XCTAssertEqual(final.actual?.joints_rad[0], 1)
        let records = try XCTUnwrap(events(application.runtime).objectValue?["events"]?.arrayValue).filter {
            ($0.objectValue?["sequence"]?.exactIntValue ?? 0) > base
        }
        XCTAssertLessThanOrEqual(records.count, 8, "Motion is sampled at most 4 Hz plus immediate critical transitions")
        XCTAssertGreaterThanOrEqual(records.count, 5)
        let last = try XCTUnwrap(records.last?.objectValue)
        XCTAssertEqual(last["event"]?.objectValue?["fields"]?.objectValue?["motion_active"], .bool(false))
        XCTAssertLessThanOrEqual(try XCTUnwrap(last["time"]?.finiteNumber), 1.52)
        let sequence = try XCTUnwrap(events(application.runtime).objectValue?["latestSequence"]?.exactIntValue)
        clock.value = 1.7
        try application.advance(domain: "robot", dt: 0.1, access: access)
        XCTAssertEqual(try events(application.runtime).objectValue?["latestSequence"]?.exactIntValue, sequence,
                       "A command baseline/final transition must not be rediscovered on the next idle step")
    }

    func testSilentWritesEnforceTheirOwnClockAndFailuresAreAtomicWithoutObservers() throws {
        let clock = Clock()
        let owner = try BCRPluginRuntime(clock: { clock.value }, epoch: "atomic")
        let id = AgentRemoteBinding.defaultInstanceID
        try owner.install([AgentRemoteBinding(instanceID: id, plugin: AgentPlugin(at: 0))])
        let before = try events(owner)
        let observer = owner.observe { _ in clock.notifications += 1 }
        defer { owner.removeObserver(observer) }
        var binding = try owner.binding(id, as: AgentRemoteBinding.self)
        clock.value = 1
        _ = try binding.plugin.handle(
            .invoke(.init(pluginID: "agent", actionID: "agent.primary", index: 1), origin: .interface),
            at: 1
        )
        try owner.replace(binding, event: nil)
        XCTAssertEqual(try owner.binding(id, as: AgentRemoteBinding.self).plugin.slots[0].state, .queued)
        XCTAssertEqual(try events(owner), before)
        clock.value = 0.5
        XCTAssertThrowsError(try owner.replace(binding, event: nil))
        clock.value = 2
        XCTAssertThrowsError(try owner.replace(binding, event: .init(code: "bad", fields: ["value": .double(.nan)])))
        clock.value = 1.5
        binding = try owner.binding(id, as: AgentRemoteBinding.self)
        _ = try binding.plugin.interrupt(1, at: 1.5)
        try owner.replace(binding, event: nil)
        XCTAssertEqual(try owner.binding(id, as: AgentRemoteBinding.self).plugin.slots[0].state, .interrupted)
        XCTAssertEqual(try events(owner), before)
        XCTAssertEqual(clock.notifications, 0)
    }
}
