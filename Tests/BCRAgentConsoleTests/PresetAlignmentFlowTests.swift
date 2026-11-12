import BCRTestSupport
import XCTest
@testable import BCRAgentConsole
@testable import BCRAgentCore
@testable import BCRCoreMIDIDriver

@MainActor
private final class PresetDevice: MIDIService {
    var connection = MIDIConnectionSnapshot(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var supportsStartupConfiguration: Bool { true }
    var preset: Data
    var written: [[UInt8]] = []
    var failAfter: Int?
    init(preset: Data) { self.preset = preset }
    func start() throws {}
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws {}
    func readCurrentPreset() async throws -> Data { preset }
    func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws {
        for (index, frame) in frames.enumerated() {
            if let failAfter, index >= failAfter { throw MIDIStartupError.noReply }
            written.append(frame); progress(index + 1)
        }
        preset = Data(frames.joined())
    }
}

@MainActor
final class PresetAlignmentFlowTests: XCTestCase {
    private func setUp(failAfter: Int? = nil) throws -> (ConsoleViewModel, PresetDevice, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let fixture = try BCLFixtures.encoderPreset()
        try stores.hardwareMap.save(fixture.hardwareMap)
        let device = PresetDevice(preset: fixture.dump)
        device.failAfter = failAfter
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        model.selectSource(.hardware)
        return (model, device, directory)
    }

    private func wait(_ model: ConsoleViewModel, until done: (PresetAlignmentState.Phase) -> Bool) async throws {
        for _ in 0 ..< 100 {
            if let phase = model.presetAlignment?.phase, done(phase) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("alignment phase did not settle: \(String(describing: model.presetAlignment?.phase))")
    }

    func testPreviewWritesNothingUntilConfirmedThenVerifiesAndInstallsMap() async throws {
        let (model, device, directory) = try setUp()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(model.canAlignPreset)
        model.beginPresetAlignment()
        try await wait(model) { $0 == .preview }
        XCTAssertTrue(device.written.isEmpty)
        let backup = try XCTUnwrap(model.presetAlignment?.backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let plan = try XCTUnwrap(model.presetAlignment?.plan)
        XCTAssertFalse(plan.isEmpty)
        model.applyPresetAlignment()
        try await wait(model) { $0 == .finished || { if case .failed = $0 { true } else { false } }($0) }
        XCTAssertEqual(model.presetAlignment?.phase, .finished)
        XCTAssertFalse(device.written.contains { String(decoding: $0, as: UTF8.self).contains("$store") })
        XCTAssertEqual(model.engine.hardwareMap.entries.filter { !$0.control.isContinuous }.count, 52)
        XCTAssertEqual(model.engine.hardwareMap.ringMode(for: .pushEncoder(group: 1, 1)), .pan)
    }

    func testFailedWriteOffersRestoreOfTheBackup() async throws {
        let (model, device, directory) = try setUp(failAfter: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = device.preset
        let mapBefore = model.engine.hardwareMap
        model.beginPresetAlignment()
        try await wait(model) { $0 == .preview }
        model.applyPresetAlignment()
        try await wait(model) { if case .failed = $0 { true } else { false } }
        XCTAssertEqual(model.presetAlignment?.canRestore, true)
        XCTAssertEqual(model.engine.hardwareMap, mapBefore)
        device.failAfter = nil
        model.restorePresetBeforeAlignment()
        try await wait(model) { $0 == .finished }
        XCTAssertEqual(device.preset, original)
        XCTAssertEqual(model.engine.hardwareMap, mapBefore)
    }

    func testRestoreWorksAfterClosingTheWindowAndAcrossRestarts() async throws {
        let (model, device, directory) = try setUp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = device.preset
        let mapBefore = model.engine.hardwareMap
        model.beginPresetAlignment()
        try await wait(model) { $0 == .preview }
        model.applyPresetAlignment()
        try await wait(model) { $0 == .finished }
        model.dismissPresetAlignment()
        XCTAssertNil(model.presetAlignment)
        XCTAssertNotNil(model.presetRestorePoint)
        XCTAssertNotEqual(device.preset, original)

        // A new app instance on the same profile still knows what to restore.
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let reopened = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        reopened.selectSource(.hardware)
        XCTAssertTrue(reopened.canRestorePreset)
        reopened.restorePresetBeforeAlignment()
        try await wait(reopened) { $0 == .finished }
        XCTAssertEqual(device.preset, original)
        XCTAssertEqual(reopened.engine.hardwareMap, mapBefore)
        XCTAssertNil(reopened.presetRestorePoint)
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: directory.appending(path: "preset-alignment-restore.json").path))
    }

    func testOpeningPreviewThreeTimesCreatesOneBackupAndNeverWritesTheDevice() async throws {
        let (model, device, directory) = try setUp()
        defer { try? FileManager.default.removeItem(at: directory) }
        var paths = Set<URL>()
        for _ in 0 ..< 3 {
            model.beginPresetAlignment()
            try await wait(model) { $0 == .preview }
            paths.insert(try XCTUnwrap(model.presetAlignment?.backup))
            model.dismissPresetAlignment()
        }
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Backups").path).count,
            1
        )
        XCTAssertTrue(device.written.isEmpty)
    }

    func testAlignmentRequiresConnectedHardware() throws {
        let (model, device, directory) = try setUp()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.selectSource(.mock)
        XCTAssertFalse(model.canAlignPreset)
        model.beginPresetAlignment()
        XCTAssertNil(model.presetAlignment)
        XCTAssertTrue(device.written.isEmpty)
    }
}
