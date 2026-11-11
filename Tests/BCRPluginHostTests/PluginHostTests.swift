import AgentPlugin
import BCRAgentDomain
import BCRConfigurationAdapter
import BCRFoundation
import BCRPluginHost
import Foundation
import SurfacePluginContracts
import XCTest

private struct FixturePlugin: ControlPlugin {
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

final class PluginRegistrationTests: XCTestCase {
    private func fixture(id: PluginID = "fixture", contract: String = "1.0",
                         actions: [ActionDescriptor] = [], failsStart: Bool = false) -> FixturePlugin
    {
        .init(manifest: .init(id: id, version: "0.1.0", contractVersion: contract, source: .mock),
              surface: .init(actions: actions), failsStart: failsStart)
    }

    func testDuplicateRegistrationAndStartupFailureLeaveNoPartialRegistration() throws {
        var registry = PluginRegistry()
        XCTAssertThrowsError(try registry.register([fixture(), fixture()], at: 0))
        XCTAssertTrue(registry.pluginIDs.isEmpty)
        XCTAssertThrowsError(try registry.snapshot("fixture"))
        XCTAssertThrowsError(try registry.register([fixture(), fixture(id: "second", failsStart: true)], at: 0))
        XCTAssertTrue(registry.pluginIDs.isEmpty)
        try registry.register([fixture()], at: 0)
        XCTAssertTrue(try registry.snapshot("fixture").isStarted)
        XCTAssertThrowsError(try registry.register([fixture(id: "second"), fixture()], at: 0))
        XCTAssertEqual(registry.pluginIDs, ["fixture"])
        XCTAssertTrue(try registry.snapshot("fixture").isStarted)
    }

    func testContractNamingAndDuplicateSurfaceIDsAreValidatedBeforeStartup() {
        let invalid = [
            fixture(contract: "2.0"), fixture(id: "bad name"),
            fixture(actions: [.init(id: "other.action", nameKey: "name")]),
            fixture(actions: [.init(id: "fixture.action", nameKey: "")]),
            fixture(actions: [.init(id: "fixture.action", nameKey: "name", indexCount: 0)]),
            fixture(actions: [.init(id: "fixture.action", nameKey: "a"),
                              .init(id: "fixture.action", nameKey: "b")])
        ]
        for plugin in invalid {
            var registry = PluginRegistry()
            XCTAssertThrowsError(try registry.register([fixture(id: "valid"), plugin], at: 0))
            XCTAssertTrue(registry.pluginIDs.isEmpty)
        }
    }

    func testResetOrStopOfOnePluginDoesNotChangeAnother() throws {
        var registry = PluginRegistry()
        try registry.register([AgentPlugin(), fixture()], at: 0)
        let other = try registry.snapshot("fixture")
        try registry.handle(.stop, for: "agent", at: 1)
        XCTAssertEqual(try registry.snapshot("fixture"), other)
        XCTAssertFalse(try registry.snapshot("agent").isStarted)
    }

    func testSurfaceIDsCannotCollideAcrossNestedPluginNamespaces() throws {
        var registry = PluginRegistry()
        try registry.register([fixture(actions: [.init(id: "fixture.child.action", nameKey: "name")])], at: 0)
        XCTAssertThrowsError(try registry.register([
            fixture(id: "fixture.child", actions: [.init(id: "fixture.child.action", nameKey: "name")])
        ], at: 0))
        XCTAssertEqual(registry.pluginIDs, ["fixture"])
    }
}

@MainActor
final class MockAgentHostTests: XCTestCase {
    private final class Clock { var time: Double = 0 }

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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try host.slots[0].state != .waitingApproval, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try host.slots[0].state, .waitingApproval)
    }
}
