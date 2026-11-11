import Foundation
import XCTest
@testable import BCRAgentCore

@MainActor
private final class FakeSurfaceDevice: SurfaceDevice {
    var connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    var failsSend = false

    func send(_ message: MIDIVoiceMessage) throws {
        if failsSend { throw SessionTestError.unavailable }
        sent.append(message)
    }

    func receive(_ messages: [MIDIVoiceMessage]) { onMessages?(messages) }

    func connect(_ connected: Bool) {
        connection = connected
            ? MIDIConnectionSnapshot(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1")
            : MIDIConnectionSnapshot()
        onConnection?(connection)
    }
}

private enum SessionTestError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "test device or store unavailable" }
}

@MainActor
private final class SessionFixture {
    let device = FakeSurfaceDevice()
    let mockDevice = MockSurfaceDevice()
    var notifications: [SurfaceSessionEvent] = []
    var triggers: [AgentSlotID] = []
    let session: SurfaceSession

    init(map: HardwareMap = .mockPreset(), configuration: SurfaceConfiguration = .robotArmDemo()) {
        // Separate retained state gives the injected clock and stores no dependency on XCTest.
        let state = FixtureState()
        session = SurfaceSession(
            hardwareDevice: device, mockDevice: mockDevice, hardwareMap: map, configuration: configuration,
            now: { state.time },
            saveHardwareMap: {
                if state.failsSave { throw SessionTestError.unavailable }
                state.maps.append($0)
            },
            saveConfiguration: {
                if state.failsSave { throw SessionTestError.unavailable }
                state.configurations.append($0)
            }
        )
        self.state = state
        session.onEvent = { [weak self] in self?.notifications.append($0) }
        session.onTriggerAgent = { [weak self] in self?.triggers.append($0) }
    }

    let state: FixtureState
}

@MainActor
private final class FixtureState {
    var time = Date(timeIntervalSinceReferenceDate: 1_000)
    var maps: [HardwareMap] = []
    var configurations: [SurfaceConfiguration] = []
    var failsSave = false
}

@MainActor
final class SurfaceSessionTests: XCTestCase {
    private let a = BCRControlID.pushEncoder(group: 1, 1)
    private let b = BCRControlID.encoder(row: 1, 1)

    func testParameterObserversSeeBatchesAndCanUnsubscribe() {
        let f = SessionFixture(configuration: mirroredConfiguration())
        var batches: [ParameterChangeBatch] = []
        let token = f.session.observeParameters { batches.append($0) }
        f.session.setParameter("j", to: 50)
        XCTAssertEqual(batches.last?.values["j"], 50)
        let revision = batches.last?.revision
        f.session.setParameter("j", to: 50)
        XCTAssertEqual(batches.last?.revision, revision)
        f.session.removeParameterObserver(token)
        f.session.setParameter("j", to: 60)
        XCTAssertEqual(batches.count, 1)
    }

    func testMonitorRecordsActualFeedbackDelivery() {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.session.selectSource(.hardware)
        XCTAssertEqual(f.session.events.last?.delivery, .disconnected)
        f.device.connect(true)
        f.session.setParameter("j", to: 50)
        XCTAssertEqual(f.session.events.last?.delivery, .sent)
        f.device.failsSend = true
        f.session.setParameter("j", to: 60)
        XCTAssertEqual(f.session.events.last?.delivery, .failed)
    }

    func testQueuedFeedbackIsCoalescedAndDiscardedOnDisconnect() throws {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.device.connect(true)
        f.session.selectSource(.hardware)
        f.device.sent.removeAll()
        try f.session.configureFeedback(.init(enabled: true, messagesPerSecond: 100, burst: 128))
        f.session.setParameter("j", to: 40)
        f.session.setParameter("j", to: 70)
        XCTAssertTrue(f.device.sent.isEmpty)
        f.session.flushFeedback()
        XCTAssertEqual(f.device.sent.filter { $0.controlID == HardwareMap.mockPreset().midi(for: a) }.last,
                       message(a, 70))
        f.session.setParameter("j", to: 90)
        f.device.connect(false)
        XCTAssertEqual(f.session.pendingFeedbackCount, 0)
    }

    func testPhysicalInputCancelsOlderQueuedOriginFeedback() throws {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.device.connect(true)
        f.session.selectSource(.hardware)
        try f.session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        f.session.flushFeedback()
        f.device.sent.removeAll()
        f.session.setParameter("j", to: 40)
        f.device.receive([message(a, 70)])
        XCTAssertEqual(f.session.engine.value(of: "j"), 70)
        f.session.flushFeedback()
        XCTAssertFalse(f.device.sent.contains { $0.controlID == message(a, 0).controlID })
        XCTAssertTrue(f.device.sent.contains(message(b, 70)))
    }

    func testFeedbackEchoDoesNotCancelNewerQueuedSoftwareValue() throws {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.device.connect(true)
        f.session.selectSource(.hardware)
        try f.session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        f.session.flushFeedback()
        f.device.sent.removeAll()
        f.session.setParameter("j", to: 70)
        f.device.receive([message(a, 30)]) // Echo of the last successfully sent initial value.
        XCTAssertEqual(f.session.engine.value(of: "j"), 70)
        f.session.flushFeedback()
        XCTAssertTrue(f.device.sent.contains(message(a, 70)))
    }

    func testSwitchingPagesDoesNotPersistOrExportSessionSelection() throws {
        var config = mirroredConfiguration()
        try config.addPage(.init(id: "second", name: "Second", assignments: config.assignments))
        let f = SessionFixture(configuration: config)
        try f.session.selectPage("second")
        XCTAssertTrue(f.state.configurations.isEmpty)
        let object = try XCTUnwrap(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(f.session.engine.configuration)) as? [String: Any])
        XCTAssertNil(object["activePageID"])
        try f.session.selectPage(SurfaceConfiguration.basePageID)
        XCTAssertTrue(f.state.configurations.isEmpty)
    }

    private func mirroredConfiguration() -> SurfaceConfiguration {
        SurfaceConfiguration(name: "Mirror", parameters: [
            ParameterDefinition(id: "j", name: "Joint", minimum: 0, maximum: 127, defaultValue: 30)
        ], assignments: [
            ControlAssignment(control: a, target: .parameter("j")),
            ControlAssignment(control: b, target: .parameter("j"))
        ])
    }

    private func message(_ control: BCRControlID, _ value: UInt8) -> MIDIVoiceMessage {
        MIDI1UMPCodec.feedback(control: HardwareMap.mockPreset().midi(for: control)!, value: value)
    }

    func testMockInputUpdatesParameterAndOnlyMirrorsOtherControl() async {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.session.synchronize()
        f.session.clearMonitor()
        let received = f.session.mock.receivedCount
        f.session.turn(a, by: 7)

        XCTAssertEqual(f.session.engine.value(of: "j"), 37)
        XCTAssertEqual(f.session.mock.value(of: a), 37)
        XCTAssertEqual(f.session.mock.value(of: b), 37)
        XCTAssertEqual(f.session.mock.receivedCount - received, 1)
        XCTAssertEqual(f.session.events.map(\.message), [message(a, 37), message(b, 37)])
        XCTAssertEqual(f.session.events.map(\.direction), [.input, .output])
        XCTAssertTrue(f.device.sent.isEmpty)
    }

    func testSoftwareParameterAndResetWriteAllMockBindings() async {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.session.setParameter("j", to: 90)
        XCTAssertEqual(f.session.mock.value(of: a), 90)
        XCTAssertEqual(f.session.mock.value(of: b), 90)
        XCTAssertEqual(f.session.events.map(\.message), [message(a, 90), message(b, 90)])
        f.session.resetGroup("")
        XCTAssertEqual(f.session.mock.value(of: a), 30)
        XCTAssertEqual(f.session.mock.value(of: b), 30)
    }

    func testDisconnectedHardwareSwitchCountsDroppedFeedbackWithoutSending() async {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.session.selectSource(.hardware)
        XCTAssertEqual(f.session.droppedFeedbackCount, 2)
        XCTAssertTrue(f.device.sent.isEmpty)
        XCTAssertEqual(f.session.events.map(\.source), [.hardware, .hardware])
        f.session.setParameter("j", to: 99)
        XCTAssertEqual(f.session.droppedFeedbackCount, 4)
        XCTAssertEqual(f.session.engine.value(of: "j"), 99)
    }

    func testReconnectWritesCurrentSnapshotAndDoesNotReplayOldFeedback() async {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.session.selectSource(.hardware)
        f.session.setParameter("j", to: 77)
        f.device.connect(true)
        XCTAssertEqual(f.device.sent, [message(a, 77), message(b, 77)])
        XCTAssertEqual(f.session.droppedFeedbackCount, 0)
        f.device.connect(true)
        XCTAssertEqual(f.device.sent.count, 2, "Repeated connected snapshots must not resend")

        f.device.connect(false)
        f.session.setParameter("j", to: 88)
        f.device.connect(true)
        XCTAssertEqual(Array(f.device.sent.suffix(2)), [message(a, 88), message(b, 88)])
        XCTAssertEqual(f.device.sent.count, 4)
    }

    func testHardwareInputInMockModeIsLoggedButDoesNotTouchParametersOrAgent() async {
        let f = SessionFixture()
        f.device.receive([message(a, 127), message(.button(row: 1, 1), 127)])
        XCTAssertEqual(f.session.engine.value(of: "arm.j1"), 0)
        XCTAssertTrue(f.triggers.isEmpty)
        XCTAssertTrue(f.notifications.isEmpty)
        XCTAssertEqual(f.session.events.count, 2)
        XCTAssertTrue(f.session.events.allSatisfy { $0.source == .hardware && $0.ignored })
        XCTAssertEqual(f.session.mock.receivedCount, 0)
    }

    func testSwitchBackToMockPreservesParametersAndSeparateHardwareMap() async throws {
        var map = HardwareMap()
        try map.bind(a, to: MIDIControlID(kind: .controlChange, channel: 3, number: 42))
        let f = SessionFixture(map: map, configuration: mirroredConfiguration())
        f.device.connect(true)
        f.session.selectSource(.hardware)
        f.session.setParameter("j", to: 91)
        XCTAssertEqual(f.device.sent.last, .controlChange(channel: 3, number: 42, value: 91))
        f.session.selectSource(.mock)
        XCTAssertEqual(f.session.mock.value(of: a), 91)
        XCTAssertEqual(f.session.mock.value(of: b), 91)
        XCTAssertEqual(f.session.engine.hardwareMap, .mockPreset())
        f.session.selectSource(.hardware)
        XCTAssertEqual(f.session.engine.hardwareMap, map)
    }

    func testLearningAdvancesRejectsConflictsAndPersistsOnlyAcceptedBindings() async {
        let f = SessionFixture(map: HardwareMap(), configuration: mirroredConfiguration())
        XCTAssertFalse(f.session.beginLearning(at: a))
        f.session.selectSource(.hardware)
        XCTAssertTrue(f.session.beginLearning(at: a))
        let first = message(a, 70)
        f.device.receive([first])
        let next = BCRControlID.pushEncoder(group: 1, 2)
        XCTAssertEqual(f.session.engine.learnTarget, next)
        XCTAssertEqual(f.state.maps.count, 1)
        XCTAssertEqual(f.state.maps.last?.midi(for: a), first.controlID)
        XCTAssertTrue(f.notifications.contains(.learned(a, first.controlID, next: next)))

        // Already-learned identity cannot steal the next target. This is intentionally
        // ignored (rather than warning on every extra encoder tick) by the engine.
        f.device.receive([message(a, 71)])
        XCTAssertNil(f.session.engine.hardwareMap.midi(for: next))
        XCTAssertEqual(f.session.engine.learnTarget, next)
        XCTAssertEqual(f.state.maps.count, 1)

        // Invalid message shape yields a visible rejection without advancing or saving.
        f.device.receive([.noteOn(channel: 0, number: 12, velocity: 127)])
        XCTAssertTrue(f.notifications.contains(.learnRejected(next, .encoderRequiresControlChange(next))))
        XCTAssertEqual(f.session.engine.learnTarget, next)
        XCTAssertEqual(f.state.maps.count, 1)
        f.device.receive([message(next, 72)])
        XCTAssertEqual(f.state.maps.count, 2)
        XCTAssertEqual(f.session.engine.learnTarget, .pushEncoder(group: 1, 3))
        XCTAssertEqual(f.session.engine.value(of: "j"), 30, "Learning must not apply functions")
    }

    func testLearningLastControlFinishesAndButtonReleaseDoesNotLearn() async {
        let f = SessionFixture(map: HardwareMap())
        f.session.selectSource(.hardware)
        let last = BCRControlID.userButton(4)
        f.session.beginLearning(at: last)
        f.device.receive([message(last, 0)])
        XCTAssertEqual(f.session.engine.learnTarget, last)
        XCTAssertTrue(f.state.maps.isEmpty)
        f.device.receive([message(last, 127)])
        XCTAssertNil(f.session.engine.learnTarget)
        XCTAssertTrue(f.notifications.contains(.learned(last, message(last, 127).controlID, next: nil)))
        XCTAssertEqual(f.state.maps.count, 1)
    }

    func testLearningStopSwitchUnbindAndResetPersistHardwareMap() async {
        let f = SessionFixture()
        f.session.selectSource(.hardware)
        f.session.beginLearning(at: a)
        f.session.stopLearning()
        XCTAssertNil(f.session.engine.learnTarget)
        f.session.beginLearning(at: a)
        f.session.selectSource(.mock)
        XCTAssertNil(f.session.engine.learnTarget)
        f.session.unbind(a)
        XCTAssertTrue(f.state.maps.isEmpty, "Mock preset cannot be edited")
        f.session.selectSource(.hardware)
        f.session.unbind(a)
        XCTAssertNil(f.state.maps.last?.midi(for: a))
        f.session.resetHardwareMap()
        XCTAssertEqual(f.state.maps.last?.boundCount, 0)
        f.session.selectSource(.mock)
        f.session.selectSource(.hardware)
        XCTAssertEqual(f.session.engine.hardwareMap.boundCount, 0)
    }

    func testAgentTriggerAndFeedbackRunThroughSessionAndSurviveConfigurationReset() async throws {
        let f = SessionFixture()
        let button = BCRControlID.button(row: 1, 1)
        f.session.press(button)
        XCTAssertEqual(f.triggers, [AgentSlotID(1)])
        f.session.setAgentFeedback(AgentSlotID(1), value: 96)
        XCTAssertEqual(f.session.mock.value(of: button), 96)
        f.session.release(button)
        XCTAssertEqual(f.session.mock.value(of: button), 96)
        XCTAssertEqual(f.triggers.count, 1)
        f.session.clearMonitor()
        try f.session.replaceConfiguration(.robotArmDemo())
        XCTAssertEqual(f.session.mock.value(of: button), 96)
        XCTAssertEqual(f.session.events.filter { $0.control == button }.count, 1)
    }

    func testPresetReplacementClearsRemovedEnableLEDThroughFeedbackPipeline() async throws {
        let f = SessionFixture()
        let enable = BCRControlID.button(row: 2, 1)
        f.session.setParameter("arm.enabled", to: 1)
        XCTAssertEqual(f.session.mock.value(of: enable), 127)
        f.session.clearMonitor()

        try f.session.replaceConfiguration(.starter())

        XCTAssertEqual(f.session.mock.value(of: enable), 0)
        XCTAssertEqual(f.session.engine.state(of: enable).value, 0)
        XCTAssertEqual(f.session.events.filter { $0.control == enable }.map(\.message), [message(enable, 0)])
        XCTAssertEqual(f.session.engine.configuration, .starter())
    }

    func testConfigurationReplacementClearsRemovedNRPNOnlyThroughLearnedHardwareIdentity() async throws {
        var map = HardwareMap()
        let learned = MIDIControlID(kind: .nrpn, channel: 3, number: 4321)
        try map.bind(b, to: learned)
        let f = SessionFixture(map: map, configuration: mirroredConfiguration())
        f.device.connect(true)
        f.session.selectSource(.hardware)
        f.session.setParameter("j", to: 90)
        f.device.sent.removeAll()

        try f.session.replaceConfiguration(.starter())

        XCTAssertEqual(f.device.sent, [MIDI1UMPCodec.feedback14(control: learned, value: 0)])
        XCTAssertEqual(f.session.engine.hardwareMap, map)
        XCTAssertEqual(f.session.engine.echoWindow, 0.18)
    }

    func testSynchronousAgentFeedbackSurvivesHeldPressIncludingRunningToInterrupted() async {
        let button = BCRControlID.button(row: 1, 1)
        let slot = AgentSlotID(1)
        for (previous, next) in [(AgentRunState.idle, AgentRunState.queued), (.running, .interrupted)] {
            let f = SessionFixture()
            let session = f.session
            session.setAgentFeedback(slot, value: previous.feedbackValue)
            // Let an intentional press at the previous LED value pass the echo window.
            f.state.time.addTimeInterval(1)
            var triggered: [AgentSlotID] = []
            session.onTriggerAgent = { [weak session] receivedSlot in
                triggered.append(receivedSlot)
                session?.setAgentFeedback(receivedSlot, value: next.feedbackValue)
            }

            session.press(button)

            XCTAssertEqual(triggered, [slot])
            XCTAssertEqual(session.engine.state(of: button).lastInput, 127)
            XCTAssertEqual(session.engine.agentFeedback[slot], next.feedbackValue)
            XCTAssertEqual(session.mock.value(of: button), next.feedbackValue,
                           "Held press must retain synchronous \(previous) → \(next) feedback before release")
            session.release(button)
            XCTAssertEqual(session.mock.value(of: button), next.feedbackValue)
            XCTAssertEqual(triggered, [slot], "Release must not trigger another Agent action")
        }
    }

    func testSendFailureReportsErrorAndCountsEveryDroppedMessage() async {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.device.connect(true)
        f.device.failsSend = true
        f.session.selectSource(.hardware)
        XCTAssertEqual(f.session.droppedFeedbackCount, 2)
        XCTAssertEqual(f.session.connection.lastError, SessionTestError.unavailable.localizedDescription)
        XCTAssertEqual(f.notifications.last, .failed(.feedback, SessionTestError.unavailable.localizedDescription))
        XCTAssertTrue(f.device.sent.isEmpty)
    }

    func testLearningPersistenceFailureRemainsVisibleAndKeepsInMemoryMapping() async {
        let f = SessionFixture(map: HardwareMap())
        f.state.failsSave = true
        f.session.selectSource(.hardware)
        f.session.beginLearning(at: a)
        f.device.receive([message(a, 70)])
        XCTAssertEqual(f.session.engine.hardwareMap.midi(for: a), message(a, 70).controlID)
        XCTAssertEqual(
            f.notifications.last,
            .failed(.hardwareMapPersistence, SessionTestError.unavailable.localizedDescription)
        )
        XCTAssertTrue(f.state.maps.isEmpty)
    }

    func testConfigurationEditsPersistAndWriteFeedback() async throws {
        let f = SessionFixture(configuration: mirroredConfiguration())
        let definition = ParameterDefinition(id: "new", name: "New", defaultValue: 55)
        try f.session.addParameter(definition, assigningTo: b)
        XCTAssertEqual(f.session.mock.value(of: b), 55)
        var updated = definition
        updated.maximum = 40
        try f.session.updateParameter(updated)
        XCTAssertEqual(f.session.mock.value(of: b), 127)
        try f.session.setAssignment(nil, for: b)
        XCTAssertNil(f.session.engine.configuration.assignment(for: b))
        f.session.removeParameter("new")
        XCTAssertNil(f.state.configurations.last?.parameter("new"))
        XCTAssertEqual(f.state.configurations.count, 4)
    }

    func testNewParameterUsesControlKindAndPersistsAssignment() async throws {
        let f = SessionFixture(configuration: mirroredConfiguration())
        let continuous = try f.session.createParameter(assigningTo: b)
        let button = BCRControlID.button(row: 2, 1)
        let toggle = try f.session.createParameter(assigningTo: button)
        XCTAssertNotEqual(continuous, toggle)
        XCTAssertEqual(f.session.engine.configuration.parameter(continuous)?.kind, .continuous)
        XCTAssertEqual(f.session.engine.configuration.parameter(toggle)?.kind, .toggle)
        XCTAssertEqual(f.state.configurations.last?.assignment(for: button)?.target, .parameter(toggle))
        XCTAssertEqual(f.state.configurations.count, 2)
    }

    func testConfigurationValidationAndSaveErrorsAreObservable() async throws {
        let f = SessionFixture(configuration: mirroredConfiguration())
        XCTAssertThrowsError(try f.session.setAssignment(
            ControlAssignment(control: a, target: .agentPrimaryAction(AgentSlotID(1))),
            for: a
        ))
        XCTAssertTrue(f.state.configurations.isEmpty)
        f.state.failsSave = true
        try f.session.updateParameter(ParameterDefinition(id: "j", name: "Updated"))
        XCTAssertEqual(
            f.notifications.last,
            .failed(.configurationPersistence, SessionTestError.unavailable.localizedDescription)
        )
        XCTAssertEqual(f.session.engine.configuration.parameter("j")?.name, "Updated")
    }

    func testInjectedClockControlsTriggerDebounce() async {
        let f = SessionFixture()
        let button = BCRControlID.button(row: 1, 1)
        f.session.press(button)
        f.session.press(button)
        XCTAssertEqual(f.triggers.count, 1)
        f.state.time.addTimeInterval(1)
        f.session.press(button)
        XCTAssertEqual(f.triggers.count, 2)
        XCTAssertEqual(f.session.events.last?.time, f.state.time)
    }

    func testInjectedClockControlsFeedbackEchoSuppression() async {
        let f = SessionFixture(configuration: mirroredConfiguration())
        f.device.connect(true)
        f.session.selectSource(.hardware)
        f.device.receive([message(a, 30)])
        XCTAssertNil(f.session.engine.state(of: a).lastInput)
        f.state.time.addTimeInterval(1)
        f.device.receive([message(a, 30)])
        XCTAssertEqual(f.session.engine.state(of: a).lastInput, 30)
        XCTAssertEqual(f.device.sent.last, message(b, 30))
    }

    func testMonitorIsBoundedClearsAndKeepsMonotonicIDs() async {
        let f = SessionFixture()
        f.device.receive(Array(repeating: message(a, 12), count: 305))
        XCTAssertEqual(f.session.events.count, 300)
        XCTAssertEqual(f.session.events.first?.id, 6)
        XCTAssertEqual(f.session.events.last?.id, 305)
        f.session.clearMonitor()
        XCTAssertTrue(f.session.events.isEmpty)
        f.device.receive([message(a, 13)])
        XCTAssertEqual(f.session.events.first?.id, 306)
    }

    func testChangingConnectedOutputRouteResendsSnapshotOnce() async {
        let fixture = SessionFixture()
        fixture.session.selectSource(.hardware)
        fixture.device.connect(true)
        fixture.device.sent.removeAll()
        var snapshot = fixture.device.connection
        snapshot.connectedDestination = "BCR2000 Port 2"
        snapshot.connectedDestinationID = 22
        fixture.device.onConnection?(snapshot)
        XCTAssertFalse(fixture.device.sent.isEmpty)
        fixture.device.sent.removeAll()
        fixture.device.onConnection?(snapshot)
        XCTAssertTrue(fixture.device.sent.isEmpty)
    }
}
