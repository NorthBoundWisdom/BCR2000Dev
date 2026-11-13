import BCRTestSupport
import XCTest
@testable import BCRAgentConsole
@testable import BCRAgentCore
@testable import BCRCoreMIDIDriver

@MainActor
private final class StartupMIDI: MIDIService {
    var connection = MIDIConnectionSnapshot(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var supportsSnapshotReadback = true
    var supportsPresets = false
    var supportsStartupConfiguration: Bool { supportsPresets }
    var suspendsNextDump = false
    var dumpInFlight = false
    var dumpContinuation: CheckedContinuation<Data, any Error>?
    var snapshotReads = 0
    var startupWrites = 0

    func readPresetNames() async throws -> BCRPresetNames {
        .init(temporary: "Drain", memory: (1 ... 32).map { $0 == 8 ? "Drain" : "P\($0)" })
    }

    func readCurrentPreset() async throws -> Data {
        if suspendsNextDump {
            suspendsNextDump = false; dumpInFlight = true
            return try await withCheckedThrowingContinuation { dumpContinuation = $0 }
        }
        return BCLFixtures.dump(["$rev R1", "$preset", ".name 'Drain'", ".lock on", "$end"])
    }

    func finishCancelledDump() {
        dumpInFlight = false
        dumpContinuation?.resume(throwing: CancellationError()); dumpContinuation = nil
    }

    func configureStartup(_ program: MIDIStartupProgram) async throws {
        guard !dumpInFlight else { throw MIDIStartupError.noReply }
        startupWrites += 1
    }

    var snapshot: [MIDIVoiceMessage] = []
    var sent: [MIDIVoiceMessage] = []
    var failure = false
    var delay = Duration.zero
    func start() throws { onConnection?(connection) }
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws {
        guard !dumpInFlight else { throw MIDIStartupError.noReply }
        sent.append(message)
    }

    func readSnapshot(expected: Set<MIDIControlID>) async throws -> [MIDIVoiceMessage] {
        guard !dumpInFlight else { throw HardwareSnapshotError.invalid }
        snapshotReads += 1
        try await Task.sleep(for: delay)
        if failure { throw HardwareSnapshotError.invalid }
        return snapshot
    }
}

@MainActor
final class HardwareStartupTests: XCTestCase {
    private func stores() -> (ConsoleStores, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return (ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                              configuration: JSONFileStore(fileURL: directory.appending(path: "config.json"))),
                directory)
    }

    private func waitForPrompt(_ model: ConsoleViewModel) async throws -> HardwareConnectionPrompt {
        for _ in 0 ..< 40 {
            if let prompt = model.pendingHardwareConnection { return prompt }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw XCTSkip("connection prompt did not appear")
    }

    private func confirmRead(_ model: ConsoleViewModel, settle: Bool = true) async throws {
        let prompt = try await waitForPrompt(model)
        XCTAssertTrue(prompt.canRead)
        model.connectHardware(prompt.id, mode: .read)
        if settle { try await Task.sleep(for: .milliseconds(80)) }
    }

    func testFirstRunWithoutLearnedControlsEntersHardwareWithoutWriting() async throws {
        let (stores, directory) = stores()
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = StartupMIDI()
        let model = ConsoleViewModel(stores: stores, midiService: device)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(model.pendingHardwareConnection)
        model.requestSource(.hardware)
        XCTAssertEqual(model.source, .hardware)
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testControlsLearnedThisRunAreOfferedAfterReconnect() async throws {
        let (stores, directory) = stores()
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = StartupMIDI()
        let model = ConsoleViewModel(stores: stores, midiService: device)
        model.requestSource(.hardware)
        model.beginLearning(at: .pushEncoder(group: 1, 1))
        device.onMessages?([.controlChange(channel: 0, number: 20, value: 5)])
        XCTAssertEqual(model.learnedCount, 1)
        let route = device.connection
        device.connection = MIDIConnectionSnapshot()
        device.onConnection?(device.connection)
        XCTAssertEqual(model.source, .mock)
        device.connection = route
        device.onConnection?(route)
        let prompt = try await waitForPrompt(model)
        XCTAssertTrue(prompt.canRead)
        XCTAssertTrue(prompt.canWrite)
    }

    func testWriteOptionEntersHardwareOnlyAfterConfirmation() async throws {
        let (stores, directory) = stores()
        defer { try? FileManager.default.removeItem(at: directory) }
        try stores.hardwareMap.save(.mockPreset())
        let device = StartupMIDI()
        let model = ConsoleViewModel(stores: stores, midiService: device)
        let prompt = try await waitForPrompt(model)
        XCTAssertTrue(device.sent.isEmpty)
        model.connectHardware(prompt.id, mode: .write)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.source, .hardware)
        XCTAssertFalse(device.sent.isEmpty)
    }

    func testEveryConnectionModeWaitsForTheCancelledDisplayStream() async throws {
        for mode in [HardwareConnectionPrompt.Mode.read, .write, .initialize] {
            let (stores, directory) = stores()
            defer { try? FileManager.default.removeItem(at: directory) }
            try stores.hardwareMap.save(.mockPreset())
            let program = try MIDIStartupProgram(
                preset: 8,
                presetSettings: [".name 'Drain'", ".snapshot off", ".request off",
                                 ".egroups 4", ".fkeys on", ".lock on"]
            )
            if mode == .initialize {
                try JSONFileStore<MIDIStartupProgram>(fileURL: directory.appending(path: "hardware-startup.json"))
                    .save(program)
            }
            let device = StartupMIDI()
            device.supportsPresets = true; device.suspendsNextDump = true
            device.snapshot = HardwareMap.mockPreset().entries.filter { $0.control.isContinuous }.map {
                MIDI1UMPCodec.feedback(control: $0.midi, value: 0)
            }
            let model = ConsoleViewModel(stores: stores, midiService: device)
            model.selectSource(.hardware)
            for _ in 0 ..< 100 {
                if device.dumpInFlight { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(device.dumpInFlight)
            model.selectSource(.mock)
            model.requestSource(.hardware)
            let prompt = try await waitForPrompt(model)
            let writes = device.sent.count
            model.connectHardware(prompt.id, mode: mode)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(model.connectingHardware)
            XCTAssertEqual(model.source, .mock)
            XCTAssertEqual(device.snapshotReads, 0)
            XCTAssertEqual(device.startupWrites, 0)
            XCTAssertEqual(device.sent.count, writes)
            device.finishCancelledDump()
            for _ in 0 ..< 100 {
                if !model.connectingHardware { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(model.source, .hardware)
            XCTAssertNotEqual(model.notice?.level, .error)
        }
    }

    func testNoticeActionAndPickerRequireConfirmationInsteadOfWriting() async throws {
        let (stores, directory) = stores()
        defer { try? FileManager.default.removeItem(at: directory) }
        try stores.hardwareMap.save(.mockPreset())
        let device = StartupMIDI()
        let model = ConsoleViewModel(stores: stores, midiService: device)
        let first = try await waitForPrompt(model)
        model.declineHardwareConnection(first.id)
        model.performNoticeAction(.switchToHardware)
        _ = try await waitForPrompt(model)
        XCTAssertEqual(model.source, .mock)
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testRemoteHardwareSwitchIsRefusedAndAsksTheUser() async throws {
        let (stores, directory) = stores()
        defer { try? FileManager.default.removeItem(at: directory) }
        try stores.hardwareMap.save(.mockPreset())
        let device = StartupMIDI()
        let model = ConsoleViewModel(stores: stores, midiService: device)
        let first = try await waitForPrompt(model)
        model.declineHardwareConnection(first.id)
        XCTAssertThrowsError(try model.mcp.service.onSelectSource?(.hardware))
        _ = try await waitForPrompt(model)
        XCTAssertEqual(model.source, .mock)
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testRequestIsTheReadOnlyBCRSnapshotCommand() {
        XCTAssertEqual(CoreMIDIService.snapshotRequest, [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x43, 0xF7])
    }

    func testStartupReadsHardwareWithoutInferringGroupFromAllGroupValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        var map = HardwareMap()
        let control = BCRControlID.pushEncoder(group: 4, 1)
        let midi = MIDIControlID(kind: .controlChange, channel: 0, number: 11)
        try map.bind(control, to: midi)
        try stores.hardwareMap.save(map)
        let device = StartupMIDI()
        device.snapshot = [MIDI1UMPCodec.feedback(control: midi, value: 3)]
        let model = ConsoleViewModel(stores: stores, midiService: device)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.source, .mock)
        XCTAssertTrue(device.sent.isEmpty)
        try await confirmRead(model)
        XCTAssertEqual(model.source, .hardware)
        XCTAssertEqual(model.displayValue(of: control), 3)
        XCTAssertNil(model.observedHardwareGroup)
        XCTAssertTrue(device.sent.isEmpty)
        device.onMessages?([MIDI1UMPCodec.feedback(control: midi, value: 4)])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.visibleGroup, 4)
        XCTAssertEqual(model.observedHardwareGroup, 4)
    }

    func testFailedStartupReadStaysInMockWithoutWritingDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        try stores.hardwareMap.save(.mockPreset())
        let device = StartupMIDI(); device.failure = true
        let model = ConsoleViewModel(stores: stores, midiService: device)
        try await confirmRead(model)
        XCTAssertEqual(model.source, .mock)
        XCTAssertEqual(model.notice?.level, .error)
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testUserEditDuringReadIsPreservedInsteadOfBeingOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        try stores.hardwareMap.save(.mockPreset())
        let device = StartupMIDI(); device.delay = .milliseconds(100)
        device.snapshot = HardwareMap.mockPreset().entries.filter { $0.control.isContinuous }.map {
            MIDI1UMPCodec.feedback(control: $0.midi, value: 0)
        }
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        try await confirmRead(model, settle: false)
        try await Task.sleep(for: .milliseconds(20))
        model.setParameter("arm.j1", to: 45)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(model.source, .mock)
        XCTAssertEqual(model.engine.value(of: "arm.j1"), 45)
        XCTAssertEqual(model.notice?.level, .error)
        XCTAssertTrue(device.sent.isEmpty)
    }
}
