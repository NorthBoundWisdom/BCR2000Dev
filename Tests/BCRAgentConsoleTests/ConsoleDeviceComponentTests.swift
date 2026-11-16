import BCRConfigurationAdapter
import BCRCoreMIDIDriver
import BCRExamples
import BCRFoundation
import BCRPersistenceAdapter
import BCRSurfaceDomain
import BCRTestSupport
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class ComponentMIDI: MIDIService {
    var connection: MIDIConnectionSnapshot = {
        var route = MIDIConnectionSnapshot(connectedSource: "Component in", connectedDestination: "Component out")
        route.connectedSourceID = 1; route.connectedDestinationID = 1
        return route
    }()

    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var supportsStartupConfiguration: Bool { true }
    var supportsSnapshotReadback: Bool { true }
    var sent: [MIDIVoiceMessage] = []
    var batches: [[[UInt8]]] = []
    var preset: Data
    var holdsDump = false
    var pendingDump: CheckedContinuation<Data, any Error>?
    init(preset: Data) { self.preset = preset }
    func start() throws { onConnection?(connection) }
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
    func readPresetNames() async throws -> BCRPresetNames {
        .init(temporary: "Component", memory: (1 ... 32).map { $0 == 8 ? "Component" : "P\($0)" })
    }

    func readCurrentPreset() async throws -> Data {
        if holdsDump { return try await withCheckedThrowingContinuation { pendingDump = $0 } }
        return preset
    }

    func completeDump(_ result: Result<Data, any Error>) {
        let pending = pendingDump; pendingDump = nil
        pending?.resume(with: result)
    }

    func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws {
        batches.append(frames)
        for index in frames.indices { try Task.checkCancellation(); progress(index + 1) }
        preset = Data(frames.joined())
    }

    func reconnect(_ id: Int32?) {
        if let id {
            connection.connectedSource = "Component in"; connection.connectedDestination = "Component out"
            connection.connectedSourceID = id; connection.connectedDestinationID = id
        } else { connection = .init() }
        onConnection?(connection)
    }
}

/// No ConsoleViewModel, ConsoleDeviceWork, MCP server or provider is constructed here.
@MainActor
private final class ComponentFixture {
    let directory: URL
    let device: ComponentMIDI
    let context: ConsoleDeviceContext
    let gate = ConsolePresetOperationGate()
    let store: ConsoleRecoveryStore
    let preset: ConsolePresetWork
    init(clock: ManualHostTime? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let fixture = try BCLFixtures.encoderPreset(name: "Component")
        device = ComponentMIDI(preset: fixture.dump)
        let mapStore = JSONFileStore<HardwareMap>(fileURL: directory.appending(path: "map.json"))
        try mapStore.save(fixture.hardwareMap)
        let hardwareFile = ProtectedJSONFile.hardware(mapStore)
        let configuration = ConfigurationPreset.robotArm.makeConfiguration()
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: fixture.hardwareMap,
                                     configuration: configuration, pluginBindings: AgentBindingTranslation.bindings,
                                     requiresHardwareConfirmation: true,
                                     saveHardwareMap: { try hardwareFile.save($0) }, saveConfiguration: { _ in })
        let timing = clock.map { ConsoleTiming(work: $0.time, presentation: $0.time) } ?? .immediate
        let ui = ConsolePresentationState(timing: timing,
                                          workspacePanelStore: JSONFileStore(fileURL: directory
                                              .appending(path: "ui.json")))
        ui.slots = AgentSlotPresentation.mockSlots()
        context = ConsoleDeviceContext(session: session, midi: device, presentation: ui, timing: timing,
                                       canConfigureMIDI: true, hardwareFile: hardwareFile)
        store = ConsoleRecoveryStore(directory: directory)
        preset = ConsolePresetWork(context: context, gate: gate, recoveryStore: store, directory: directory)
    }

    func recovery() -> ConsoleRecoveryWork {
        let result = ConsoleRecoveryWork(context: context, preset: preset, gate: gate, store: store)
        preset.recovery = result
        return result
    }

    func connection(recovery: ConsoleRecoveryWork) -> ConsoleConnectionWork {
        let output = OutputController(session: context.session,
                                      store: JSONFileStore(fileURL: directory.appending(path: "output.json")),
                                      automaticallyTicks: false)
        let result = ConsoleConnectionWork(context: context,
                                           endpointStore: JSONFileStore(fileURL: directory
                                               .appending(path: "endpoints.json")),
                                           selection: .init(), endpointError: nil, output: output,
                                           preset: preset, recovery: recovery)
        preset.isConnecting = { [weak result] in result?.connectingHardware ?? false }
        preset.isStarting = { [weak result] in result?.startingMIDI ?? false }
        recovery.isConnecting = { [weak result] in result?.connectingHardware ?? false }
        context.session.onChange = { [weak result, weak preset, weak recovery] in
            preset?.validateConnectionWork(); recovery?.validateConnectionWork(); result?.validateConnectionWork()
        }
        return result
    }

    func prepareRestorePoint() throws -> PresetRestorePoint {
        let backup = try store.saveBackup(device.preset)
        let point = PresetRestorePoint(backupFile: backup.lastPathComponent,
                                       hardwareMap: context.session.learnedHardwareMap,
                                       createdAt: .now, route: PresetRestoreRoute(device.connection),
                                       expectedPreset: device.preset,
                                       expectedHardwareMap: context.session.learnedHardwareMap,
                                       acknowledgedLines: 1, backupDigest: PresetBackupStore.digest(device.preset))
        try store.saveRestorePoint(point)
        return point
    }

    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class ConnectionTransactionProbe: ConsoleConnectionPresetPort, ConsoleConnectionRecoveryPort {
    var displayReadTask: Task<Void, Never>?
    var alignmentTask: Task<Void, Never>?
    var restoreTask: Task<Void, Never>?
    var presetSourceSwitchBlocked = false
    func clearNumberContext() {}
    func invalidateDisplayNumber() {}
}

@MainActor
final class ConsoleConnectionComponentTests: XCTestCase {
    func testIndependentConnectionRejectsOldPromptAndKeepsWriteSynchronous() async throws {
        let fixture = try ComponentFixture(); defer { fixture.removeFiles() }
        let recovery = fixture.recovery(), connection = fixture.connection(recovery: recovery)
        connection.offerHardwareConnection()
        try await waitUntil { connection.pendingHardwareConnection != nil }
        let old = try XCTUnwrap(connection.pendingHardwareConnection)
        fixture.device.reconnect(nil); fixture.device.reconnect(2)
        connection.offerHardwareConnection()
        try await waitUntil { connection.pendingHardwareConnection != nil }
        let current = try XCTUnwrap(connection.pendingHardwareConnection)
        XCTAssertNotEqual(old.id, current.id)
        connection.connectHardware(old.id, mode: .write)
        XCTAssertEqual(fixture.context.session.source, .mock)
        XCTAssertTrue(fixture.device.sent.isEmpty)
        connection.connectHardware(current.id, mode: .write)
        XCTAssertEqual(fixture.context.session.source, .hardware)
        XCTAssertFalse(connection.connectingHardware)
        XCTAssertTrue(connection.backgroundTasks.isEmpty)
        XCTAssertFalse(fixture.device.sent.isEmpty)
    }

    func testIndependentConnectionDrainsAllThreeActualTransactionHandles() async throws {
        let fixture = try ComponentFixture(); defer { fixture.removeFiles() }
        let probe = ConnectionTransactionProbe()
        var releaseDisplay: CheckedContinuation<Void, Never>?
        var releaseAlignment: CheckedContinuation<Void, Never>?
        var releaseRestore: CheckedContinuation<Void, Never>?
        probe.displayReadTask = Task { await withCheckedContinuation { releaseDisplay = $0 } }
        probe.alignmentTask = Task { await withCheckedContinuation { releaseAlignment = $0 } }
        probe.restoreTask = Task { await withCheckedContinuation { releaseRestore = $0 } }
        try await waitUntil { releaseDisplay != nil && releaseAlignment != nil && releaseRestore != nil }
        let output = OutputController(session: fixture.context.session,
                                      store: JSONFileStore(fileURL: fixture.directory.appending(path: "output.json")),
                                      automaticallyTicks: false)
        let owner = ConsoleConnectionWork(context: fixture.context,
                                          endpointStore: JSONFileStore(fileURL: fixture.directory
                                              .appending(path: "endpoints.json")),
                                          selection: .init(), endpointError: nil, output: output,
                                          preset: probe, recovery: probe)
        owner.offerHardwareConnection()
        try await waitUntil { owner.pendingHardwareConnection != nil }
        owner.connectHardware(try XCTUnwrap(owner.pendingHardwareConnection).id, mode: .write)
        let connectionTask = try XCTUnwrap(owner.backgroundTasks.last)
        XCTAssertTrue(try XCTUnwrap(probe.displayReadTask).isCancelled)
        XCTAssertEqual(fixture.context.session.source, .mock)
        XCTAssertTrue(fixture.device.sent.isEmpty)
        releaseDisplay?.resume(); releaseAlignment?.resume()
        try await XCTUnwrap(probe.alignmentTask).value
        await Task.yield()
        XCTAssertTrue(owner.connectingHardware)
        XCTAssertEqual(fixture.context.session.source, .mock)
        XCTAssertTrue(fixture.device.sent.isEmpty)
        releaseRestore?.resume()
        await connectionTask.value
        XCTAssertEqual(fixture.context.session.source, .hardware)
        XCTAssertFalse(owner.connectingHardware)
        XCTAssertFalse(fixture.device.sent.isEmpty)
    }

    func testIndependentConnectionAwaitsActualCancelledDisplayHandle() async throws {
        let fixture = try ComponentFixture(); defer { fixture.removeFiles() }
        let recovery = fixture.recovery(), connection = fixture.connection(recovery: recovery)
        fixture.context.session.selectSource(.hardware)
        fixture.device.holdsDump = true
        fixture.preset.refreshDisplayFromDevice()
        try await waitUntil { fixture.device.pendingDump != nil }
        let original = try XCTUnwrap(fixture.preset.displayReadTask)
        connection.selectSource(.mock); connection.offerHardwareConnection()
        try await waitUntil { connection.pendingHardwareConnection != nil }
        let mark = fixture.device.sent.count
        connection.connectHardware(try XCTUnwrap(connection.pendingHardwareConnection).id, mode: .write)
        XCTAssertTrue(original.isCancelled)
        XCTAssertEqual(fixture.preset.displayReadTask, original)
        XCTAssertTrue(connection.connectingHardware)
        XCTAssertEqual(fixture.context.session.source, .mock)
        XCTAssertEqual(fixture.device.sent.count, mark)
        fixture.device.completeDump(.failure(CancellationError()))
        let task = try XCTUnwrap(connection.backgroundTasks.last)
        await task.value
        XCTAssertEqual(fixture.context.session.source, .hardware)
        XCTAssertFalse(connection.connectingHardware)
    }
}

@MainActor
final class ConsolePresetComponentTests: XCTestCase {
    func testIndependentPresetCancelledOldReadCannotClearReplacementHandle() async throws {
        let fixture = try ComponentFixture(); defer { fixture.removeFiles() }
        fixture.context.session.selectSource(.hardware)
        fixture.device.holdsDump = true
        fixture.preset.refreshDisplayFromDevice()
        try await waitUntil { fixture.device.pendingDump != nil }
        let first = try XCTUnwrap(fixture.preset.displayReadTask)
        fixture.preset.refreshDisplayFromDevice()
        let second = try XCTUnwrap(fixture.preset.displayReadTask)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.isCancelled)
        fixture.device.completeDump(.failure(CancellationError()))
        await first.value
        try await waitUntil { fixture.device.pendingDump != nil }
        XCTAssertEqual(fixture.preset.displayReadTask, second)
        fixture.device.completeDump(.success(fixture.device.preset))
        await second.value
        XCTAssertNil(fixture.preset.displayReadTask)
        XCTAssertEqual(fixture.preset.displayProfile?.name, "Component")
        XCTAssertTrue(fixture.device.batches.isEmpty)
    }

    func testIndependentAlignmentOwnsTaskAndPersistsVerifiedRecoveryContext() async throws {
        let fixture = try ComponentFixture(); defer { fixture.removeFiles() }
        fixture.context.session.selectSource(.hardware)
        fixture.preset.beginPresetAlignment()
        try await XCTUnwrap(fixture.preset.alignmentTask).value
        XCTAssertEqual(fixture.preset.presetAlignment?.phase, .preview)
        fixture.preset.applyPresetAlignment()
        let task = try XCTUnwrap(fixture.preset.alignmentTask)
        await task.value
        XCTAssertNil(fixture.preset.alignmentTask)
        XCTAssertNil(fixture.gate.id)
        XCTAssertEqual(fixture.preset.presetAlignment?.phase, .finished)
        let point = try XCTUnwrap(fixture.store.presetRestorePoint)
        XCTAssertEqual(point.expectedPreset, fixture.device.preset)
        XCTAssertEqual(point.expectedHardwareMap, fixture.context.session.learnedHardwareMap)
        XCTAssertGreaterThan(point.acknowledgedLines ?? 0, 0)
        XCTAssertEqual(fixture.device.batches.count, 1)
    }
}

@MainActor
final class ConsoleRecoveryComponentTests: XCTestCase {
    func testIndependentRestoreRejectsChangedConfirmationContextWithoutWrites() async throws {
        let fixture = try ComponentFixture(); defer { fixture.removeFiles() }
        fixture.context.session.selectSource(.hardware)
        let point = try fixture.prepareRestorePoint(), recovery = fixture.recovery()
        fixture.context.session.unbind(.encoder(row: 1, 1))
        recovery.restorePresetBeforeAlignment()
        try await XCTUnwrap(recovery.restoreTask).value
        XCTAssertEqual(fixture.preset.presetAlignment?.phase, .restoreConfirmation)
        XCTAssertNotNil(recovery.pendingPresetRestore)
        fixture.context.session.unbind(.encoder(row: 1, 2))
        recovery.confirmPresetRestoreReplacingLearning()
        try await XCTUnwrap(recovery.restoreTask).value
        guard case .failed = fixture.preset.presetAlignment?.phase else { return XCTFail("changed map must reject") }
        XCTAssertNil(recovery.restoreTask)
        XCTAssertNil(fixture.gate.id)
        XCTAssertTrue(fixture.device.batches.isEmpty)
        XCTAssertEqual(fixture.store.presetRestorePoint, point)
    }

    func testIndependentRestoreRouteLossCancelsActualTaskAndRetainsRecoveryPoint() async throws {
        let fixture = try ComponentFixture(); defer { fixture.removeFiles() }
        fixture.context.session.selectSource(.hardware)
        let point = try fixture.prepareRestorePoint(), recovery = fixture.recovery()
        fixture.device.holdsDump = true
        recovery.restorePresetBeforeAlignment()
        try await waitUntil { fixture.device.pendingDump != nil }
        let task = try XCTUnwrap(recovery.restoreTask)
        fixture.device.reconnect(nil)
        recovery.validateConnectionWork()
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(recovery.restoreTask, task)
        fixture.device.completeDump(.failure(CancellationError()))
        await task.value
        XCTAssertNil(recovery.restoreTask)
        XCTAssertNil(fixture.gate.id)
        XCTAssertEqual(fixture.store.presetRestorePoint, point)
        XCTAssertTrue(fixture.device.batches.isEmpty)
    }
}

@MainActor
final class ConsoleButtonFeedbackComponentTests: XCTestCase {
    func testIndependentLEDClockKeepsActualTimerAndSteadyStateStopsTraffic() async throws {
        let clock = ManualHostTime(), fixture = try ComponentFixture(clock: clock)
        defer { fixture.removeFiles() }
        var map = fixture.context.session.learnedHardwareMap
        try map.bind(.button(row: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 65))
        try fixture.context.session.installHardwareMap(map)
        fixture.context.session.selectSource(.hardware)
        let codex = CodexAgentController(directory: fixture.directory)
        let owner = ConsoleButtonFeedbackWork(context: fixture.context, codex: codex, directory: fixture.directory)
        var slots = fixture.context.presentation.slots
        slots[0].state = .waitingApproval
        fixture.device.sent.removeAll()
        owner.applyAgentSlots(slots, changed: slots[0].id)
        let timer = try XCTUnwrap(owner.blinkTask)
        try await waitUntil { clock.pendingDeadlines.contains(0.05) }
        XCTAssertEqual(fixture.device.sent.map(\.midi1Bytes), [[176, 65, 127]])
        let mark = fixture.device.sent.count
        clock.advance(by: 0.199)
        try await waitUntil { clock.pendingDeadlines.contains(clock.now + 0.05) }
        XCTAssertEqual(fixture.device.sent.count, mark)
        XCTAssertEqual(owner.blinkTask, timer)
        clock.advance(by: 0.051)
        try await waitUntil { fixture.device.sent.count > mark }
        slots[0].state = .running
        owner.applyAgentSlots(slots, changed: slots[0].id)
        XCTAssertTrue(timer.isCancelled)
        XCTAssertNil(owner.blinkTask)
        let steady = fixture.device.sent.count
        clock.advance(by: 1)
        await Task.yield()
        XCTAssertEqual(fixture.device.sent.count, steady)
        owner.setBlinksAgentLEDs(false)
        XCTAssertEqual(
            try JSONFileStore<Bool>(fileURL: fixture.directory.appending(path: "agent-led-blink.json")).load(),
            false
        )
    }
}
