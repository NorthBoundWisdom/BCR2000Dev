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
        try await Task.sleep(for: .milliseconds(80))
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
        try await Task.sleep(for: .milliseconds(20))
        model.setParameter("arm.j1", to: 45)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(model.source, .mock)
        XCTAssertEqual(model.engine.value(of: "arm.j1"), 45)
        XCTAssertEqual(model.notice?.level, .error)
        XCTAssertTrue(device.sent.isEmpty)
    }
}
