import AgentPlugin
import BCRAgentDomain
import BCRConfigurationAdapter
import BCRFoundation
import BCRPluginHost
import BCRPluginRuntime
import AgentRemoteBinding
import RemoteToolContracts
import Foundation
import SurfacePluginContracts
import XCTest

private struct FixturePlugin: ControlPlugin, RemoteBinding {
    var instanceID: String { manifest.id.rawValue }
    var tools: [RemoteToolDescriptor] { [] }
    mutating func call(_ name: String, arguments: JSONValue,
                       context: RemoteCallContext) throws -> JSONValue { throw PluginError(code: .unsupported) }
    let manifest: PluginManifest
    let surface: SurfaceDescriptor
    var failsStart = false
    var started = false
    mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        if input == .start {
            if failsStart { throw PluginError(code: .notInitialized) }
            started = true
        }
        return .init()
    }

    func snapshot() -> PluginSnapshot { .init(isStarted: started) }
}

@MainActor
final class PluginRegistrationTests: XCTestCase {
    private func instanceIDs(_ registry: BCRPluginRuntime) throws -> [String] {
        let data = try registry.call("surface_capabilities", arguments: .object([:]))
        return try XCTUnwrap(data.objectValue?["instances"]?.arrayValue)
            .compactMap { $0.objectValue?["instance_id"]?.stringValue }
    }

    private func snapshot(_ registry: BCRPluginRuntime, _ id: String) throws -> PluginSnapshot {
        guard let value = registry.snapshot(id) else { throw PluginError(code: .unsupported) }
        return value
    }

    private func fixture(id: PluginID = "fixture", contract: String = "1.0",
                         actions: [ActionDescriptor] = [], failsStart: Bool = false) -> FixturePlugin
    {
        .init(manifest: .init(id: id, version: "0.1.0", contractVersion: contract, source: .mock),
              surface: .init(actions: actions), failsStart: failsStart)
    }

    func testDuplicateRegistrationAndStartupFailureLeaveNoPartialRegistration() throws {
        let registry = try BCRPluginRuntime(clock: { 0 }, epoch: "fixture")
        XCTAssertThrowsError(try registry.install([fixture(), fixture()]))
        XCTAssertTrue(try instanceIDs(registry).isEmpty)
        XCTAssertThrowsError(try snapshot(registry, "fixture"))
        XCTAssertThrowsError(try registry.install([fixture(), fixture(id: "second", failsStart: true)]))
        XCTAssertTrue(try instanceIDs(registry).isEmpty)
        try registry.install([fixture()])
        XCTAssertTrue(try snapshot(registry, "fixture").isStarted)
        XCTAssertThrowsError(try registry.install([fixture(id: "second"), fixture()]))
        XCTAssertEqual(try instanceIDs(registry), ["fixture"])
        XCTAssertTrue(try snapshot(registry, "fixture").isStarted)
    }

    func testContractNamingAndDuplicateSurfaceIDsAreValidatedBeforeStartup() throws {
        let invalid = [
            fixture(contract: "2.0"), fixture(id: "bad name"),
            fixture(actions: [.init(id: "other.action", nameKey: "name")]),
            fixture(actions: [.init(id: "fixture.action", nameKey: "")]),
            fixture(actions: [.init(id: "fixture.action", nameKey: "name", indexCount: 0)]),
            fixture(actions: [.init(id: "fixture.action", nameKey: "a"),
                              .init(id: "fixture.action", nameKey: "b")])
        ]
        for plugin in invalid {
            let registry = try BCRPluginRuntime(clock: { 0 }, epoch: "fixture")
            XCTAssertThrowsError(try registry.install([fixture(id: "valid"), plugin]))
            XCTAssertTrue(try instanceIDs(registry).isEmpty)
        }
    }

    func testResetOrStopOfOnePluginDoesNotChangeAnother() throws {
        let registry = try BCRPluginRuntime(clock: { 0 }, epoch: "fixture")
        try registry.install([AgentRemoteBinding(instanceID: "agent", plugin: try AgentPlugin()), fixture()])
        let other = try snapshot(registry, "fixture")
        try registry.handle("agent", input: .stop)
        XCTAssertEqual(try snapshot(registry, "fixture"), other)
        XCTAssertFalse(try snapshot(registry, "agent").isStarted)
    }

    func testSurfaceIDsCannotCollideAcrossNestedPluginNamespaces() throws {
        let registry = try BCRPluginRuntime(clock: { 0 }, epoch: "fixture")
        try registry.install([fixture(actions: [.init(id: "fixture.child.action", nameKey: "name")])])
        XCTAssertThrowsError(try registry.install([
            fixture(id: "fixture.child", actions: [.init(id: "fixture.child.action", nameKey: "name")])
        ]))
        XCTAssertEqual(try instanceIDs(registry), ["fixture"])
    }
}

@MainActor
final class MockAgentHostTests: XCTestCase {
    private final class Clock { var time: Double = 0 }

    func testSameReferenceSequenceAsTheOtherHostMatchesSharedRegistryAndRemoteApprovalRejection() throws {
        let clock = Clock()
        let owner = try BCRPluginRuntime(clock: { clock.time }, epoch: "fixture")
        let host = try BCRMockAgentHost(clock: { clock.time }, runtime: owner)
        var reference = try RemoteRegistry(epoch: "fixture")
        try reference.install(AgentRemoteBinding(instanceID: BCRMockAgentHost.instanceID,
                                                 plugin: AgentPlugin(
                                                     slotCount: 8,
                                                     approvalPolicy: .localOrigins,
                                                     at: 0
                                                 )))
        _ = try reference.handle(instanceID: BCRMockAgentHost.instanceID, input: .start, at: 0)
        let arguments: JSONValue = .object(["instance_id": .string(BCRMockAgentHost.instanceID), "slot": .number(1)])
        clock.time = 1
        XCTAssertEqual(try owner.call("surface_agent_primary", arguments: arguments),
                       try reference.call("surface_agent_primary", arguments: arguments, context: .init(time: 1)))
        for time in [1.45, 2, 3.7] {
            clock.time = time
            try host.advance()
            _ = try reference.handle(instanceID: BCRMockAgentHost.instanceID, input: .advance, at: time)
            XCTAssertEqual(try host.snapshot(), reference.snapshot(instanceID: BCRMockAgentHost.instanceID))
        }
        clock.time = 4
        let before = try host.snapshot()
        XCTAssertThrowsError(try owner.call("surface_agent_primary", arguments: arguments))
        XCTAssertThrowsError(try reference.call("surface_agent_primary", arguments: arguments, context: .init(time: 4)))
        XCTAssertEqual(try host.snapshot(), before)
        let cursor: JSONValue = .object(["epoch": .string("fixture"), "after": .string("0"), "limit": .number(256)])
        XCTAssertEqual(try owner.call("surface_events", arguments: cursor),
                       try reference.call("surface_events", arguments: cursor, context: .init(time: 4)))
    }

    func testEveryInjectedTimelineStageMatchesSharedPluginSnapshotAndLegacyProgress() throws {
        let clock = Clock()
        let host = try BCRMockAgentHost(clock: { clock.time }, epoch: Date(timeIntervalSince1970: 1000))
        var shared = try AgentPlugin(at: 0)
        _ = try shared.handle(.start, at: 0)
        let slot = AgentSlotID(1)
        let action = try AgentBindingTranslation.action(for: slot)
        XCTAssertEqual(action, .init(pluginID: "agent", actionID: "agent.primary", index: 1))
        var states: [String] = []
        var progress: [Double] = []
        host.onUpdate = { slots, _ in states.append(slots[0].state.rawValue); progress.append(slots[0].progress) }
        try host.invoke(slot, origin: .interface)
        _ = try shared.handle(.invoke(action, origin: .interface), at: clock.time)
        XCTAssertEqual(try host.snapshot(), shared.snapshot())
        for time in [0.45, 1, 1.55, 2.1, 2.65] {
            clock.time = time
            try host.advance()
            _ = try shared.handle(.advance, at: time)
            XCTAssertEqual(try host.snapshot(), shared.snapshot())
        }
        XCTAssertEqual(states, ["queued", "running", "running", "running", "running", "running", "waitingApproval"])
        XCTAssertEqual(progress, [0, 0.08, 0.20, 0.34, 0.48, 0.58, 0.60])
        XCTAssertEqual(try host.slots[0].lastUpdated, Date(timeIntervalSince1970: 1002.65))
        XCTAssertEqual(try host.slots[0].statusText, L10n.text("等待批准：运行 Mock 验证"))
        try host.invoke(slot, origin: .hardware) // Mock retains the existing device-approval behavior.
        _ = try shared.handle(.invoke(action, origin: .hardware), at: clock.time)
        for time in [2.65 + 0.6, 2.65 + 1.2, 2.65 + 1.8, 2.65 + 2.25] {
            clock.time = time
            try host.advance()
            _ = try shared.handle(.advance, at: time)
            XCTAssertEqual(try host.snapshot(), shared.snapshot())
        }
        XCTAssertEqual(Array(progress.suffix(5)), [0.64, 0.72, 0.84, 0.94, 1])
        XCTAssertEqual(try host.slots[0].state, .completed)
    }

    func testLargeTickReplaysAllStagesAndFeedbackInOriginalOrder() throws {
        let clock = Clock()
        let host = try BCRMockAgentHost(clock: { clock.time })
        var progress: [Double] = []
        var values: [UInt8] = []
        host.onUpdate = { slots, feedback in
            progress.append(slots[0].progress)
            if let value = feedback[AgentSlotID(1)] { values.append(value) }
        }
        try host.invoke(AgentSlotID(1), origin: .interface)
        clock.time = 100
        try host.advance()
        XCTAssertEqual(progress, [0, 0.08, 0.2, 0.34, 0.48, 0.58, 0.6])
        XCTAssertEqual(values, [40, 127, 127, 127, 127, 127, 96])
    }

    func testDeclineInterruptsWaitingSlotAndPreservesOtherSlotAndCancelledTimeline() throws {
        let clock = Clock()
        let host = try BCRMockAgentHost(clock: { clock.time })
        try host.invoke(AgentSlotID(1), origin: .interface)
        try host.invoke(AgentSlotID(2), origin: .interface)
        clock.time = 2.65
        try host.advance()
        try host.interrupt(AgentSlotID(1))
        XCTAssertEqual(try host.slots[0].state, .interrupted)
        XCTAssertEqual(try host.slots[1].state, .waitingApproval)
        clock.time = 100
        try host.advance()
        XCTAssertEqual(try host.slots[0].state, .interrupted)
        XCTAssertEqual(try host.slots[1].state, .waitingApproval)
    }

    func testSemanticFeedbackMappingPinsAllSevenLegacyValues() {
        XCTAssertEqual(IndicatorSemantic.allCases.map(BCRIndicatorPresentation.value), [0, 40, 127, 96, 72, 20, 8])
    }

    func testButtonLEDLightsFrom64LikeTheDevice() {
        XCTAssertFalse(BCRButtonLED.isLit(63))
        XCTAssertTrue(BCRButtonLED.isLit(64))
        // With blinking off, only active, waiting and done states light a device LED.
        XCTAssertEqual(
            IndicatorSemantic.allCases.filter { BCRButtonLED.isLit(BCRIndicatorPresentation.value(for: $0)) },
            [.active, .attention, .done]
        )
    }

    func testInvalidLegacySlotInputIsAVisibleErrorWithUnchangedPluginSnapshot() throws {
        let host = try BCRMockAgentHost(clock: { 0 })
        let before = try host.snapshot()
        for index in [0, 9, Int.max] {
            XCTAssertThrowsError(try host.invoke(AgentSlotID(index), origin: .interface))
            XCTAssertThrowsError(try host.interrupt(AgentSlotID(index)))
            XCTAssertEqual(try host.snapshot(), before)
        }
    }

    func testMainActorDriverAdvancesWithoutAWindowOrRefreshCallback() async throws {
        let clock = Clock()
        let host = try BCRMockAgentHost(clock: { clock.time })
        try host.invoke(AgentSlotID(1), origin: .interface)
        clock.time = 2.65
        host.startDriving()
        defer { host.stopDriving() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try host.slots[0].state != .waitingApproval, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try host.slots[0].state, .waitingApproval)
    }
}
