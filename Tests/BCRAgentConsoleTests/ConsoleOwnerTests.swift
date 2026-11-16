import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import BCRCoreMIDIDriver
import BCRTestSupport
import Combine
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class OwnerCredential: MCPCredentialStore {
    func loadOrCreate() async throws -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() +
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

@MainActor
private final class OwnerMIDI: MIDIService {
    var connection = MIDIConnectionSnapshot(connectedSource: "Owner in", connectedDestination: "Owner out")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var supportsSnapshotReadback = true
    var supportsPresets = false
    var supportsStartupConfiguration: Bool { supportsPresets }
    var sent: [MIDIVoiceMessage] = []
    var snapshotInFlight = false
    var dumpInFlight = false
    var snapshot: CheckedContinuation<[MIDIVoiceMessage], any Error>?
    var dump: CheckedContinuation<Data, any Error>?
    var holdDump = true
    init() { connection.connectedSourceID = 1; connection.connectedDestinationID = 1 }
    func start() throws { onConnection?(connection) }
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
    func reconnect(_ route: Int32?) {
        connection = route.map { value in
            var result = MIDIConnectionSnapshot(connectedSource: "Owner in", connectedDestination: "Owner out")
            result.connectedSourceID = value; result.connectedDestinationID = value; return result
        } ?? .init()
        onConnection?(connection)
    }

    func readSnapshot(expected: Set<MIDIControlID>) async throws -> [MIDIVoiceMessage] {
        snapshotInFlight = true
        defer { snapshotInFlight = false }
        return try await withCheckedThrowingContinuation { snapshot = $0 }
    }

    func finishSnapshot() {
        snapshot?.resume(returning: [.controlChange(channel: 0, number: 81, value: 10)]); snapshot = nil
    }

    func readPresetNames() async throws -> BCRPresetNames {
        .init(temporary: "Owner", memory: (1 ... 32).map { $0 == 8 ? "Owner" : "P\($0)" })
    }

    func readCurrentPreset() async throws -> Data {
        guard holdDump else { throw MIDIStartupError.noReply }
        dumpInFlight = true
        defer { dumpInFlight = false }
        return try await withCheckedThrowingContinuation { dump = $0 }
    }

    func finishCancelledDump() {
        holdDump = false
        dump?.resume(throwing: CancellationError()); dump = nil
    }
}

@MainActor
final class ConsoleDeviceWorkOwnerTests: XCTestCase {
    private func make(_ directory: URL, _ midi: OwnerMIDI) throws -> ConsoleDeviceWork {
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        var map = HardwareMap()
        try map.bind(.encoder(row: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 81))
        try stores.hardwareMap.save(map)
        try stores.configuration.save(.init(name: "Owner", parameters: [
            .init(id: "p", name: "p", minimum: 0, maximum: 127, defaultValue: 10)
        ], assignments: [.init(control: .encoder(row: 1, 1), target: .parameter("p"))]))
        return ConsoleDeviceWork(stores: stores, mcpCredentials: OwnerCredential(), midiService: midi,
                                 automaticallyAdvancesMock: false, timing: .immediate)
    }

    func testDirectOwnerRejectsOldRoutePromptAndPreservesSynchronousWriteFastPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let midi = OwnerMIDI(), work = try make(directory, midi)
        try await waitUntil { work.pendingHardwareConnection != nil }
        let old = try XCTUnwrap(work.pendingHardwareConnection)
        XCTAssertTrue(midi.sent.isEmpty)
        work.declineHardwareConnection(old.id)
        midi.reconnect(nil); midi.reconnect(2)
        try await waitUntil { work.pendingHardwareConnection != nil }
        let current = try XCTUnwrap(work.pendingHardwareConnection)
        XCTAssertNotEqual(old.id, current.id)
        work.connectHardware(old.id, mode: .write)
        XCTAssertEqual(work.source, .mock)
        XCTAssertEqual(work.pendingHardwareConnection?.id, current.id)
        XCTAssertTrue(midi.sent.isEmpty)
        work.connectHardware(current.id, mode: .write)
        // No await: the old no-in-flight-work branch must be synchronous.
        XCTAssertEqual(work.source, .hardware)
        XCTAssertEqual(midi.sent.map(\.midi1Bytes), [[176, 81, 10]])
    }

    func testDirectOwnerPreservesUserEditWhileSnapshotIsHeld() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let midi = OwnerMIDI(), work = try make(directory, midi)
        try await waitUntil { work.pendingHardwareConnection != nil }
        work.connectHardware(try XCTUnwrap(work.pendingHardwareConnection).id, mode: .read)
        try await waitUntil { midi.snapshotInFlight }
        work.setParameter("p", to: 42)
        midi.finishSnapshot()
        try await work.waitForBackgroundWork()
        XCTAssertEqual(work.source, .mock)
        XCTAssertEqual(work.engine.value(of: "p"), 42)
        XCTAssertTrue(midi.sent.isEmpty)
    }

    func testDirectOwnerDrainsCancelledDisplayAndOldTaskCannotClearNewConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let midi = OwnerMIDI(); midi.supportsPresets = true
        let work = try make(directory, midi)
        try await waitUntil { work.pendingHardwareConnection != nil }
        work.selectSource(.hardware)
        try await waitUntil { midi.dumpInFlight }
        let mark = midi.sent.count
        work.selectSource(.mock)
        work.requestSource(.hardware)
        try await waitUntil { work.pendingHardwareConnection != nil }
        work.connectHardware(try XCTUnwrap(work.pendingHardwareConnection).id, mode: .write)
        try await waitUntil { work.connectingHardware }
        let firstTasks = Set(work.backgroundTasks)
        XCTAssertTrue(midi.dumpInFlight)
        XCTAssertEqual(work.source, .mock)
        XCTAssertEqual(midi.sent.count, mark)
        work.selectSource(.mock) // Cancels the pending writer, but must not pretend the device drained.
        work.requestSource(.hardware)
        try await waitUntil { work.pendingHardwareConnection != nil }
        work.connectHardware(try XCTUnwrap(work.pendingHardwareConnection).id, mode: .write)
        XCTAssertFalse(Set(work.backgroundTasks).subtracting(firstTasks).isEmpty)
        XCTAssertEqual(work.source, .mock)
        XCTAssertTrue(midi.dumpInFlight)
        midi.finishCancelledDump()
        try await work.waitForBackgroundWork()
        XCTAssertEqual(work.source, .hardware)
        XCTAssertFalse(work.connectingHardware)
        XCTAssertFalse(midi.dumpInFlight)
        XCTAssertEqual(midi.sent.count, mark + 1)
    }
}

@MainActor
final class ConsolePresentationOwnerTests: XCTestCase {
    private func state(_ clock: ManualHostTime, _ directory: URL) -> ConsolePresentationState {
        .init(timing: .init(work: clock.time, presentation: clock.time),
              workspacePanelStore: JSONFileStore(fileURL: directory.appending(path: "panels.json")))
    }

    func testIndependentStateCoalescesOneFrameAndKeepsActualTaskIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualHostTime(), state = state(clock, directory)
        state.followsTouch = false
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        state.pendingTouchedControl = .pushEncoder(group: 2, 1)
        state.scheduleFrame(); let first = state.uiPublishTask
        state.pendingTouchedControl = .pushEncoder(group: 3, 4)
        state.scheduleFrame()
        XCTAssertEqual(state.uiPublishTask, first)
        try await waitUntil { clock.pendingCount == 1 }
        XCTAssertEqual(publications, 0)
        clock.advance(by: 0.015)
        XCTAssertEqual(publications, 0)
        clock.advance(by: 0.001)
        try await waitUntil { state.uiPublishTask == nil }
        XCTAssertEqual(publications, 1)
        subscription.cancel()
        state.followsTouch = true
        state.selectGroup = { state.visibleGroup = $0 }
        defer { state.selectGroup = nil }
        let selected = BCRControlID.pushEncoder(group: 2, 3)
        state.pendingTouchedControl = selected; state.scheduleFrame()
        try await waitUntil { clock.pendingCount == 1 }
        clock.advance(by: 0.016)
        try await waitUntil { state.uiPublishTask == nil }
        XCTAssertEqual(state.selectedControl, selected)
        XCTAssertEqual(state.visibleGroup, 2)
    }

    func testIndependentNoticeExactBoundaryStickyErrorsAndAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualHostTime(), state = state(clock, directory)
        state.notice = .init(level: .info, text: "Transient")
        try await waitUntil { clock.pendingCount == 1 }
        clock.advance(by: 5.999); XCTAssertNotNil(state.notice)
        clock.advance(by: 0.001)
        try await waitUntil { state.notice == nil }
        let error = ConsoleNotice(level: .error, text: "Keep")
        state.notice = error; clock.advance(by: 10)
        XCTAssertEqual(state.notice, error)
        let action = ConsoleNotice(level: .info, text: "Action", action: .switchToHardware)
        state.notice = action; clock.advance(by: 10)
        XCTAssertEqual(state.notice, action)
    }

    func testIndependentPressAndActivityUseOriginalDurationBoundaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualHostTime(), state = state(clock, directory)
        let button = BCRControlID.button(row: 1, 1)
        state.noteButtonActivity(button, pressed: true)
        clock.advance(by: 0.01); state.noteButtonActivity(button, pressed: false)
        try await waitUntil { clock.pendingCount == 1 }
        clock.advance(by: 0.069); XCTAssertTrue(state.hardwarePressedControls.contains(button))
        clock.advance(by: 0.001)
        try await waitUntil { !state.hardwarePressedControls.contains(button) }
        state.noteDeviceActivity()
        try await waitUntil { clock.pendingCount == 1 }
        clock.advance(by: 0.119); XCTAssertTrue(state.deviceActivity)
        clock.advance(by: 0.001)
        try await waitUntil { !state.deviceActivity }
    }

    func testIndependentTransferTokensCanFinishInReverseOrder() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let state = state(ManualHostTime(), directory)
        let first = state.beginTransfer(.read), second = state.beginTransfer(.write)
        XCTAssertEqual(state.display.transfers, 2)
        state.endTransfer(second); XCTAssertEqual(state.display.transfers, 1)
        state.endTransfer(first); XCTAssertEqual(state.display.transfers, 0)
    }
}
