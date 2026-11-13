import BCRTestSupport
import XCTest
@testable import BCRAgentConsole
@testable import BCRAgentCore
@testable import BCRCoreMIDIDriver

@MainActor
private final class RestoreSafetyDevice: MIDIService {
    var connection = MIDIConnectionSnapshot(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var supportsPresets = true
    var supportsStartupConfiguration: Bool { supportsPresets }
    var preset: Data
    var batches: [[[UInt8]]] = []
    var failAtFrame: Int?
    var corruptReadAfterBatch: Int?
    var unexpectedPresetAfterBatch: Int?
    var onNames: (() -> Void)?
    var afterFrame: ((Int) -> Void)?
    var nameReads = 0
    var memory: [Int: Data] = [:]
    var memoryReads = 0
    var suspendsNextDump = false
    var suspendedDump: CheckedContinuation<Data, any Error>?
    init(_ preset: Data) { self.preset = preset }
    func start() throws {}
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws {}
    func readPresetNames() async throws -> BCRPresetNames {
        nameReads += 1
        onNames?()
        let name = try BCRDisplayProfile.read(fromPresetDump: preset).name ?? ""
        let names = memory.isEmpty ? [] : (1 ... 32).map { memory[$0] == nil ? "P\($0)" : name }
        return .init(temporary: name, memory: names)
    }

    func readCurrentPreset() async throws -> Data {
        if suspendsNextDump {
            suspendsNextDump = false
            return try await withCheckedThrowingContinuation { suspendedDump = $0 }
        }
        if corruptReadAfterBatch == batches.count {
            var lines = try BCRPresetAlignment.canonicalLines(of: preset)
            lines.insert(".request on", at: 2)
            return BCLFixtures.dump(lines)
        }
        return preset
    }

    func readMemoryPreset(_ number: Int) async throws -> Data {
        memoryReads += 1
        guard let dump = memory[number] else { throw MIDIStartupError.noReply }
        return dump
    }

    func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws {
        batches.append([])
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            if failAtFrame == index { throw MIDIStartupError.noReply }
            batches[batches.count - 1].append(frame)
            progress(index + 1)
            afterFrame?(index + 1)
        }
        preset = Data(frames.joined())
        if unexpectedPresetAfterBatch == batches.count {
            var lines = try BCRPresetAlignment.canonicalLines(of: preset)
            lines.insert(".request on", at: 2)
            preset = BCLFixtures.dump(lines)
        }
    }
}

@MainActor
final class PresetRestoreSafetyTests: XCTestCase {
    private func context(aligned: Bool = true) async throws
        -> (ConsoleViewModel, RestoreSafetyDevice, ConsoleStores, URL)
    {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: root.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: root.appending(path: "config.json")))
        let fixture = try BCLFixtures.encoderPreset(name: "Safety")
        try stores.hardwareMap.save(fixture.hardwareMap)
        let device = RestoreSafetyDevice(fixture.dump)
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        model.selectSource(.hardware)
        if aligned { try await align(model) }
        return (model, device, stores, root)
    }

    private func settle(_ model: ConsoleViewModel, _ predicate: (PresetAlignmentState.Phase) -> Bool) async throws {
        for _ in 0 ..< 200 {
            if let phase = model.presetAlignment?.phase, predicate(phase) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Operation failed to settle: \(String(describing: model.presetAlignment?.phase))")
    }

    private func failed(_ phase: PresetAlignmentState.Phase) -> Bool {
        if case .failed = phase { return true }; return false
    }

    private func align(_ model: ConsoleViewModel, enable: Bool = false) async throws {
        model.beginPresetAlignment()
        try await settle(model) { $0 == .preview }
        var options = BCRPresetAlignment.Options(); options.enableButtonFunctions = enable
        model.setAlignmentOptions(options)
        model.applyPresetAlignment()
        try await settle(model) { $0 == .finished || self.failed($0) }
        XCTAssertEqual(model.presetAlignment?.phase, .finished)
    }

    func testSourceSwitchRequestsCannotInterruptAlignmentOrRestore() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        device.afterFrame = { done in
            guard done == 1 else { return }
            attempts += 1
            do {
                try model.mcp.service
                    .onSelectSource?(.mock); XCTFail("MCP must reject a source switch during transfer")
            } catch {}
            model.selectSource(.mock)
            XCTAssertEqual(model.source, .hardware)
        }
        try await align(model)
        model.restorePresetBeforeAlignment(); try await settle(model) { $0 == .finished }
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(model.presetRestorePoint)
    }

    func testPendingRestoreConfirmationRejectsSourceSwitch() async throws {
        let (model, _, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        model.unbind(.userButton(1))
        model.restorePresetBeforeAlignment(); try await settle(model) { $0 == .restoreConfirmation }
        XCTAssertThrowsError(try model.mcp.service.onSelectSource?(.mock))
        model.selectSource(.mock)
        XCTAssertEqual(model.source, .hardware)
        model.cancelPresetRestore()
        model.selectSource(.mock)
        XCTAssertEqual(model.source, .mock)
    }

    func testReconnectCannotRaceAnAlignmentReadThatIsStillDraining() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        device.suspendsNextDump = true
        model.beginPresetAlignment()
        for _ in 0 ..< 100 {
            if device.suspendedDump != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(device.suspendedDump)
        let route = device.connection
        device.connection = .init(); device.onConnection?(device.connection)
        device.connection = route; device.onConnection?(route)
        XCTAssertEqual(model.source, .mock)
        XCTAssertThrowsError(try model.mcp.service.onSelectSource?(.hardware))
        model.requestSource(.hardware)
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.source, .mock)
        XCTAssertNil(model.pendingHardwareConnection)
        device.suspendedDump?.resume(throwing: CancellationError()); device.suspendedDump = nil
        try await settle(model, failed)
        model.dismissPresetAlignment()
        model.requestSource(.hardware)
        for _ in 0 ..< 100 {
            if model.pendingHardwareConnection != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(model.pendingHardwareConnection)
        XCTAssertTrue(device.batches.isEmpty)
    }

    func testLockedUnknownPresetPreviewDoesNotDumpSameNamedMemorySlots() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        device.memory = [1: try BCLFixtures.encoderPreset(name: "Safety").dump,
                         8: BCLFixtures.dump(["$rev R1", "$preset", ".name 'Safety'", "$end"])]
        // Drop all process-local number evidence, as after a reconnect with an edited working copy.
        model.selectSource(.mock); model.selectSource(.hardware)
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        XCTAssertEqual(model.deviceKeysLocked, true)
        XCTAssertEqual(device.memoryReads, 0)
        XCTAssertEqual(model.displayText, "----")
    }

    func testRestoreRejectsMockUnsupportedDisconnectedAndChangedRouteWithoutWriting() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = device.batches.count
        model.selectSource(.mock)
        XCTAssertFalse(model.canRestorePreset)
        model.restorePresetBeforeAlignment()
        XCTAssertEqual(model.notice?.level, .warning)
        model.selectSource(.hardware)
        device.supportsPresets = false
        XCTAssertFalse(model.canRestorePreset)
        model.restorePresetBeforeAlignment()
        device.supportsPresets = true
        let old = device.connection
        device.connection = .init(); device.onConnection?(device.connection)
        XCTAssertFalse(model.canRestorePreset)
        device.connection = old; device.connection.connectedSourceID = 99
        device.onConnection?(device.connection); model.selectSource(.hardware)
        XCTAssertFalse(model.canRestorePreset)
        model.restorePresetBeforeAlignment()
        XCTAssertEqual(device.batches.count, count)
    }

    func testRestoreRejectsDifferentPresetNameBeforeAnyWrite() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        device.preset = try BCLFixtures.encoderPreset(name: "Different").dump
        let count = device.batches.count
        model.restorePresetBeforeAlignment()
        try await settle(model, failed)
        XCTAssertEqual(device.batches.count, count)
        XCTAssertNotNil(model.presetRestorePoint)
    }

    func testRestoreRejectsSameNameWithDifferentDefinitions() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        device.preset = try BCLFixtures.encoderPreset(name: "Safety").dump
        let count = device.batches.count
        model.restorePresetBeforeAlignment()
        try await settle(model, failed)
        XCTAssertEqual(device.batches.count, count)
        XCTAssertNotNil(model.presetRestorePoint)
    }

    func testRouteChangeDuringReadOnlyPreflightCannotWrite() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = device.batches.count
        device.onNames = {
            device.connection.connectedDestinationID = 82
            device.onConnection?(device.connection)
        }
        model.restorePresetBeforeAlignment()
        try await settle(model, failed)
        XCTAssertEqual(device.batches.count, count)
    }

    func testRouteChangeDuringRestoreStopsBeforeNextFrame() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        device.afterFrame = { done in
            if done == 1 {
                device.connection.connectedDestinationID = 81
                device.onConnection?(device.connection)
            }
        }
        model.restorePresetBeforeAlignment()
        try await settle(model, failed)
        XCTAssertEqual(device.batches.last?.count, 1)
        XCTAssertNotNil(model.presetRestorePoint)
    }

    func testRestoreAcknowledgementsDoNotReplaceFullReadbackVerification() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let point = model.presetRestorePoint, map = model.engine.hardwareMap
        device.corruptReadAfterBatch = device.batches.count + 1
        model.restorePresetBeforeAlignment()
        try await settle(model, failed)
        XCTAssertEqual(device.batches.count, 2)
        XCTAssertEqual(model.presetRestorePoint?.backupFile, point?.backupFile)
        XCTAssertEqual(model.presetRestorePoint?.hardwareMap, point?.hardwareMap)
        XCTAssertEqual(model.presetRestorePoint?.restoreAttempted, true)
        XCTAssertEqual(model.engine.hardwareMap, map)
    }

    func testRepeatedAlignmentRetainsBothRestoreLevels() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try BCLFixtures.encoderPreset(name: "Safety").dump
        let first = try XCTUnwrap(model.presetRestorePoint)
        let firstAligned = device.preset
        try await align(model, enable: true)
        XCTAssertEqual(model.presetRestorePoint?.history?.count, 1)
        XCTAssertTrue(model.presetRestorePoint?.protectedFiles.contains(first.backupFile) == true)
        model.restorePresetBeforeAlignment()
        try await settle(model) { $0 == .finished }
        XCTAssertEqual(device.preset, firstAligned)
        XCTAssertEqual(model.presetRestorePoint?.backupFile, first.backupFile)
        model.restorePresetBeforeAlignment()
        try await settle(model) { $0 == .finished }
        XCTAssertEqual(device.preset, original)
        XCTAssertNil(model.presetRestorePoint)
    }

    func testLaterLearningRequiresConfirmationAndIsArchivedBeforeReplacement() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        model.unbind(.userButton(1)); model.beginLearning(at: .userButton(1))
        device.onMessages?([.controlChange(channel: 14, number: 120, value: 127)])
        model.stopLearning()
        let learned = model.engine.hardwareMap, count = device.batches.count
        model.restorePresetBeforeAlignment()
        try await settle(model) { $0 == .restoreConfirmation }
        XCTAssertEqual(device.batches.count, count)
        XCTAssertEqual(model.engine.hardwareMap, learned)
        model.confirmPresetRestoreReplacingLearning()
        try await settle(model) { $0 == .finished }
        let archives = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Backups"),
                                                                   includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("hardware-map-before-restore-") }
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try JSONFileStore<HardwareMap>(fileURL: XCTUnwrap(archives.first)).load(), learned)
        let archive = try XCTUnwrap(archives.first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int, 0o600)
        let presentedPath = root.appending(path: "Backups").appending(path: archive.lastPathComponent).path
        XCTAssertTrue(model.notice?.text.contains(presentedPath) == true)
    }

    func testCancelRestoreConfirmationPreservesLaterLearning() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        model.unbind(.userButton(1)); model.beginLearning(at: .userButton(1))
        device.onMessages?([.controlChange(channel: 14, number: 120, value: 127)]); model.stopLearning()
        let map = model.engine.hardwareMap, count = device.batches.count
        model.restorePresetBeforeAlignment()
        try await settle(model) { $0 == .restoreConfirmation }
        model.cancelPresetRestore()
        XCTAssertEqual(device.batches.count, count)
        XCTAssertEqual(model.engine.hardwareMap, map)
        XCTAssertNotNil(model.presetRestorePoint)
    }

    func testRestoreReportsFrameProgress() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        var seen: [Int] = []
        device.afterFrame = { _ in seen.append(model.presetAlignment?.restoreProgress?.done ?? -1) }
        model.restorePresetBeforeAlignment()
        try await settle(model) { $0 == .finished }
        XCTAssertEqual(seen.first, 1)
        XCTAssertEqual(seen.last, device.batches.last?.count)
    }

    func testEditingConfigurationDuringWriteDoesNotChangeConfirmedReadbackContract() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        // Enable host button functions, so the second plan is nonempty without changing the preset name.
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        var options = BCRPresetAlignment.Options(); options.enableButtonFunctions = true
        model.setAlignmentOptions(options)
        let confirmed = try XCTUnwrap(model.presetAlignment?.plan).lines
        device.afterFrame = { done in
            if done == 1, var definition = model.configuration.parameter("arm.j1") {
                definition.minimum = 0
                _ = model.updateParameter(definition)
            }
        }
        model.applyPresetAlignment()
        try await settle(model) { $0 == .finished || self.failed($0) }
        XCTAssertEqual(model.presetAlignment?.phase, .finished)
        XCTAssertTrue(try BCRPresetAlignment.readbackMatches(device.preset, expected: confirmed))
    }

    func testFirstAcknowledgementIsDurableWithoutRewritingEveryLine() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        let store = JSONFileStore<PresetRestorePoint>(fileURL: root.appending(path: "preset-alignment-restore.json"))
        device.afterFrame = { done in
            do {
                let saved = try store.load()
                XCTAssertEqual(saved?.acknowledgedLines, 1)
            } catch { XCTFail("Progress was not persisted: \(error)") }
        }
        model.applyPresetAlignment(); try await settle(model) { $0 == .finished }
        XCTAssertEqual(try store.load()?.acknowledgedLines, device.batches.last?.count)
    }

    func testLockedAlignmentCarriesContentProvenNumberAndRestoreResolvesOriginal() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        device.memory = [1: device.preset, 8: BCLFixtures.dump(["$rev R1", "$preset", ".name 'Safety'", "$end"])]
        try await align(model)
        XCTAssertEqual(model.deviceKeysLocked, true)
        XCTAssertEqual(model.displayText, "P- 1")
        let proofStore = JSONFileStore<[PresetNumberRecord]>(fileURL: root
            .appending(path: "preset-number-evidence.json"))
        XCTAssertTrue(try XCTUnwrap(proofStore.load()).allSatisfy { $0.uniquenessProven == true })
        let reads = device.memoryReads
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        XCTAssertEqual(model.displayText, "P- 1")
        XCTAssertEqual(device.memoryReads, reads)
        model.dismissPresetAlignment()
        model.requestPresetNumberConfirmation()
        for _ in 0 ..< 100 {
            if model.pendingPresetNumberConfirmation != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let confirmation = try XCTUnwrap(model.pendingPresetNumberConfirmation)
        model.confirmDisplayPresetNumber(confirmation.id, number: 1)
        model.restorePresetBeforeAlignment(); try await settle(model) { $0 == .finished }
        XCTAssertEqual(model.displayText, "P- 1")
        // Reconnecting reads the working copy again; the identical aligned definition was proven
        // as slot 1 on this route, so its definition-bound record restores the number without
        // re-reading the same-named slots (which could never match an edited copy).
        try await align(model)
        let readsBeforeReconnect = device.memoryReads
        model.selectSource(.mock); model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.displayText, "P- 1")
        XCTAssertEqual(device.memoryReads, readsBeforeReconnect)
        XCTAssertTrue(try XCTUnwrap(proofStore.load()).allSatisfy { $0.uniquenessProven == true })
    }

    func testRestoreAfterRestartUsesTheContentProofOfTheRestoredDefinition() async throws {
        let (model, device, stores, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        device.memory = [1: device.preset, 8: BCLFixtures.dump(["$rev R1", "$preset", ".name 'Safety'", "$end"])]
        // The preview proves slot 1 for the original definition by comparing the same-named slots.
        try await align(model)
        XCTAssertEqual(model.displayText, "P- 1")
        model.dismissPresetAlignment()

        // 2026-11-14 on hardware: after an app restart the restore wrote the original back but showed ----.
        let restarted = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        restarted.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(restarted.displayText, "P- 1")
        let reads = device.memoryReads
        restarted.restorePresetBeforeAlignment(); try await settle(restarted) { $0 == .finished }
        XCTAssertEqual(restarted.displayText, "P- 1")
        XCTAssertEqual(device.memoryReads, reads, "the recorded proof needs no further slot dumps")
    }

    func testFailedWriteCannotKeepThePreviousLockProof() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        device.memory = [1: device.preset, 8: BCLFixtures.dump(["$rev R1", "$preset", ".name 'Safety'", "$end"])]
        try await align(model)
        XCTAssertEqual(model.displayText, "P- 1")
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        var options = BCRPresetAlignment.Options(); options.enableButtonFunctions = true
        model.setAlignmentOptions(options)
        device.failAtFrame = 5
        model.applyPresetAlignment(); try await settle(model, failed)
        XCTAssertEqual(model.displayText, "----")
    }

    func testManualOnlyProofDoesNotBecomeUniqueThroughAlignmentOrRestore() async throws {
        let (model, device, stores, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = device.preset
        device.memory = [1: original, 8: original]
        try await Task.sleep(for: .milliseconds(100))
        model.requestPresetNumberConfirmation()
        for _ in 0 ..< 100 {
            if model.pendingPresetNumberConfirmation != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let confirmation = try XCTUnwrap(model.pendingPresetNumberConfirmation)
        model.confirmDisplayPresetNumber(confirmation.id, number: 1)
        try await align(model)
        let restartedDevice = RestoreSafetyDevice(device.preset)
        restartedDevice.memory = device.memory
        let restarted = ConsoleViewModel(stores: stores, midiService: restartedDevice)
        restarted.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(restarted.displayContent, .unknown)
        model.restorePresetBeforeAlignment(); try await settle(model) { $0 == .finished }
        let records = try JSONFileStore<[PresetNumberRecord]>(fileURL: root
            .appending(path: "preset-number-evidence.json"))
            .load()
        XCTAssertTrue(records?.allSatisfy { $0.uniquenessProven == false } == true)
        XCTAssertEqual(model.displayContent, .preset(1), "Manual proof still works within its uninterrupted session")
    }

    func testUnlockedAlignmentCannotCarryAnAmbiguousNumber() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        device.memory = [1: device.preset, 8: BCLFixtures.dump(["$rev R1", "$preset", ".name 'Safety'", "$end"])]
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        var options = BCRPresetAlignment.Options(); options.lockPreset = false
        model.setAlignmentOptions(options)
        model.applyPresetAlignment(); try await settle(model) { $0 == .finished }
        XCTAssertEqual(model.displayText, "----")
    }

    func testDiscardUnusableTopLevelRevealsOlderLevelWithoutWriting() async throws {
        let (model, device, stores, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try XCTUnwrap(model.presetRestorePoint)
        let broken = PresetRestorePoint(backupFile: "legacy.syx", hardwareMap: HardwareMap(), createdAt: .now,
                                        acknowledgedLines: 0, history: [previous])
        let store = JSONFileStore<PresetRestorePoint>(fileURL: root.appending(path: "preset-alignment-restore.json"))
        try store.save(broken)
        let reopened = ConsoleViewModel(stores: stores, midiService: device)
        reopened.selectSource(.hardware)
        XCTAssertFalse(reopened.canRestorePreset)
        XCTAssertTrue(reopened.canDiscardPresetRestore)
        let map = reopened.engine.hardwareMap, count = device.batches.count
        reopened.discardPresetRestore(broken)
        XCTAssertEqual(reopened.presetRestorePoint, previous)
        XCTAssertEqual(try store.load(), previous)
        XCTAssertEqual(reopened.engine.hardwareMap, map)
        XCTAssertEqual(device.batches.count, count)
        // A stale confirmation cannot discard the next level.
        reopened.discardPresetRestore(broken)
        XCTAssertEqual(reopened.presetRestorePoint, previous)
        reopened.restorePresetBeforeAlignment(); try await settle(reopened) { $0 == .finished }
        XCTAssertNil(reopened.presetRestorePoint)
    }

    func testDiscardLastLegacyLevelRemovesRecordAndKeepsBackup() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let point = try XCTUnwrap(model.presetRestorePoint), count = device.batches.count
        model.discardPresetRestore(point)
        XCTAssertNil(model.presetRestorePoint)
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: root.appending(path: "preset-alignment-restore.json").path))
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: root.appending(path: "Backups").appending(path: point.backupFile).path))
        XCTAssertEqual(device.batches.count, count)
    }

    func testZeroAcknowledgementFailureDoesNotOfferANewRestore() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = model.presetRestorePoint
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        var options = BCRPresetAlignment.Options(); options.enableButtonFunctions = true
        model.setAlignmentOptions(options); device.failAtFrame = 0
        model.applyPresetAlignment(); try await settle(model, failed)
        XCTAssertEqual(model.presetRestorePoint, previous)
    }

    func testLegacyRestoreMetadataIsKeptButCannotAuthorizeADeviceWrite() async throws {
        let (model, device, stores, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(model.presetRestorePoint)
        try JSONFileStore<PresetRestorePoint>(fileURL: root.appending(path: "preset-alignment-restore.json"))
            .save(.init(
                backupFile: original.backupFile,
                hardwareMap: original.hardwareMap,
                createdAt: original.createdAt
            ))
        let reopened = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        reopened.selectSource(.hardware)
        let count = device.batches.count
        XCTAssertNotNil(reopened.presetRestorePoint)
        XCTAssertFalse(reopened.canRestorePreset)
        reopened.restorePresetBeforeAlignment()
        XCTAssertEqual(reopened.notice?.level, .warning)
        XCTAssertEqual(device.batches.count, count)
    }

    func testFirstWriteWithNoAcknowledgementHasNoRestorePoint() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        device.failAtFrame = 0
        model.applyPresetAlignment(); try await settle(model, failed)
        XCTAssertNil(model.presetRestorePoint)
        XCTAssertFalse(model.presetAlignment?.canRestore ?? true)
        XCTAssertFalse(model.canRestorePreset)
    }

    func testDeviceIDChangeIsRejectedEvenWithSameNameAndDefinitions() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        device.preset = BCLFixtures.dump(try BCRPresetAlignment.canonicalLines(of: device.preset), device: 1)
        let count = device.batches.count
        model.restorePresetBeforeAlignment(); try await settle(model, failed)
        XCTAssertEqual(device.batches.count, count)
    }

    func testBackupContentChangeIsRejectedBeforeWriting() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let point = try XCTUnwrap(model.presetRestorePoint), count = device.batches.count
        let path = root.appending(path: "Backups").appending(path: point.backupFile)
        try device.preset.write(to: path)
        model.restorePresetBeforeAlignment(); try await settle(model, failed)
        XCTAssertEqual(device.batches.count, count)
        XCTAssertEqual(model.presetRestorePoint, point)
    }

    func testOrdinaryValueChangesDoNotMasqueradeAsAPresetChange() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        var lines = try BCRPresetAlignment.canonicalLines(of: device.preset)
        let index = try XCTUnwrap(lines.firstIndex(of: "$encoder 1"))
        lines.insert(".default 73", at: index + 1)
        device.preset = BCLFixtures.dump(lines)
        model.restorePresetBeforeAlignment(); try await settle(model) { $0 == .finished }
        XCTAssertNil(model.presetRestorePoint)
    }

    func testMappingChangeDuringConfirmationPreflightCannotBeOverwritten() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        model.unbind(.userButton(1))
        model.restorePresetBeforeAlignment(); try await settle(model) { $0 == .restoreConfirmation }
        let count = device.batches.count
        device.onNames = { model.unbind(.userButton(2)) }
        model.confirmPresetRestoreReplacingLearning(); try await settle(model, failed)
        XCTAssertEqual(device.batches.count, count)
        XCTAssertNil(model.engine.hardwareMap.midi(for: .userButton(2)))
    }

    func testLearningDisablesRestoreAndShowsReason() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        model.unbind(.userButton(1)); model.beginLearning(at: .userButton(1))
        let count = device.batches.count
        XCTAssertFalse(model.canRestorePreset)
        XCTAssertNotNil(model.restoreUnavailableReason)
        model.restorePresetBeforeAlignment()
        XCTAssertEqual(model.notice?.level, .warning)
        XCTAssertEqual(device.batches.count, count)
        model.stopLearning()
    }

    func testChangedPresetAfterPreviewCannotBeAlignedBlindly() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        device.preset = try BCLFixtures.encoderPreset(name: "Switched").dump
        model.applyPresetAlignment(); try await settle(model, failed)
        XCTAssertTrue(device.batches.isEmpty)
        XCTAssertNil(model.presetRestorePoint)
    }

    func testChangesAfterPreviewRequireANewConfirmation() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        model.unbind(.pushEncoder(group: 1, 1))
        model.applyPresetAlignment()
        XCTAssertTrue(device.batches.isEmpty)
        XCTAssertEqual(model.notice?.level, .warning)
    }

    func testMappingChangeDuringFinalReadCannotBeSilentlyInstalledOver() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        let namesBefore = device.nameReads
        device.onNames = {
            if device.nameReads == namesBefore + 2 { model.unbind(.userButton(2)) }
        }
        model.restorePresetBeforeAlignment(); try await settle(model, failed)
        XCTAssertNil(model.engine.hardwareMap.midi(for: .userButton(2)))
        XCTAssertNotNil(model.presetRestorePoint)
    }

    func testAlignmentRejectsUnrelatedReadbackChangeWithoutInstallingTheMap() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalMap = model.engine.hardwareMap
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        device.corruptReadAfterBatch = 1
        model.applyPresetAlignment(); try await settle(model, failed)
        XCTAssertEqual(model.engine.hardwareMap, originalMap)
        XCTAssertNotNil(model.presetRestorePoint)
        XCTAssertEqual(device.batches.count, 1)
    }

    func testFailedAlignmentCannotBlessAnUnexpectedSameNamedDocument() async throws {
        let (model, device, _, root) = try await context(aligned: false)
        defer { try? FileManager.default.removeItem(at: root) }
        model.beginPresetAlignment(); try await settle(model) { $0 == .preview }
        device.unexpectedPresetAfterBatch = 1
        model.applyPresetAlignment(); try await settle(model, failed)
        let count = device.batches.count
        model.restorePresetBeforeAlignment(); try await settle(model, failed)
        XCTAssertEqual(device.batches.count, count)
        XCTAssertNotNil(model.presetRestorePoint)
    }

    func testFailedRestoreVerificationCanRetryOnlyTheAlreadyApprovedBackup() async throws {
        let (model, device, _, root) = try await context()
        defer { try? FileManager.default.removeItem(at: root) }
        device.corruptReadAfterBatch = 2
        model.restorePresetBeforeAlignment(); try await settle(model, failed)
        XCTAssertNotNil(model.presetRestorePoint)
        device.corruptReadAfterBatch = nil
        model.restorePresetBeforeAlignment(); try await settle(model) { $0 == .finished }
        XCTAssertNil(model.presetRestorePoint)
    }
}
