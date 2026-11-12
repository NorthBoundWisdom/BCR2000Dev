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
    var snapshot: [MIDIVoiceMessage] = []
    var sent: [MIDIVoiceMessage] = []
    var failure = false
    var delay = Duration.zero
    func start() throws { onConnection?(connection) }
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
    func readSnapshot(expected: Set<MIDIControlID>) async throws -> [MIDIVoiceMessage] {
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
        XCTAssertEqual(model.source, .hardware)
        XCTAssertFalse(device.sent.isEmpty)
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
