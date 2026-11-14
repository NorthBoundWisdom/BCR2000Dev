import BCRTestSupport
import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

@MainActor
private final class EndpointFakeMIDI: MIDIService {
    var connection = MIDIConnectionSnapshot(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var choices: [MIDIEndpointSelection] = []
    var starts = 0
    func send(_ message: MIDIVoiceMessage) throws {}
    func start() throws { starts += 1; onConnection?(connection) }
    func selectEndpoints(_ selection: MIDIEndpointSelection) { choices.append(selection) }
}

@MainActor
private final class EndpointFakeOutput: OutputTransport {
    var isConnected = false
    var onSamples: (@MainActor ([ParameterSample]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    func start(host: String, port: UInt16) throws { isConnected = true; onConnection?(true, nil) }
    func ping(at now: Date) throws {}
    func send(_ frame: ParameterOutputFrame) throws {}
    func stop() { isConnected = false }
}

@MainActor
final class MIDIEndpointSettingsTests: XCTestCase {
    private func stores(_ directory: URL) -> ConsoleStores {
        .init(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
              configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
    }

    func testChoicePersistsStopsOutputAndPreservesParameterValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let midi = EndpointFakeMIDI(), output = EndpointFakeOutput()
        let model = ConsoleViewModel(stores: stores(directory), midiService: midi, outputTransport: output,
                                     initialPreset: .robotArm)
        model.setParameter("arm.j1", to: 45)
        model.output.start()
        defer { model.output.stop() }
        XCTAssertTrue(model.output.settings.enabled)
        let choice = MIDIEndpointSelection(sourceID: 1, destinationID: 3)
        model.applyEndpointSelection(choice)
        XCTAssertEqual(model.endpointSelection, choice)
        XCTAssertEqual(midi.choices.last, choice)
        XCTAssertFalse(model.output.settings.enabled)
        XCTAssertEqual(model.engine.value(of: "arm.j1"), 45)
        let saved = try JSONFileStore<MIDIEndpointSelection>(fileURL: directory.appending(path: "midi-endpoints.json"))
            .load()
        XCTAssertEqual(saved, choice)
    }

    func testMCPEndpointToolPersistsTheSameChoiceAsTheSettingsSheet() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let midi = EndpointFakeMIDI()
        midi.connection.sourceEndpoints = [.init(id: 7, name: "BCR2000")]
        midi.connection.destinationEndpoints = [.init(id: 9, name: "BCR2000")]
        let model = ConsoleViewModel(stores: stores(directory), midiService: midi)
        try await waitUntil { !model.startingMIDI && model.connection.sourceEndpoints.count == 1 }
        model.mcp.service.permissions.deviceControl = true
        let result = model.mcp.service.call("set_midi_endpoints", arguments: .object([
            "sourceID": .number(7), "destinationID": .number(9)
        ]))
        XCTAssertFalse(result.isError, "\(result.value)")
        let choice = MIDIEndpointSelection(sourceID: 7, destinationID: 9)
        XCTAssertEqual(model.endpointSelection, choice)
        XCTAssertEqual(midi.choices.last, choice)
        XCTAssertEqual(try JSONFileStore<MIDIEndpointSelection>(
            fileURL: directory.appending(path: "midi-endpoints.json")
        ).load(), choice)
        XCTAssertEqual(model.mcp.service.call("list_midi_endpoints").value.objectValue?["selection"], result.value)
    }

    func testMCPEndpointToolRefusesWhileOutputRunsOrALearnIsActive() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let midi = EndpointFakeMIDI(), output = EndpointFakeOutput()
        midi.connection.sourceEndpoints = [.init(id: 7, name: "BCR2000")]
        midi.connection.destinationEndpoints = [.init(id: 9, name: "BCR2000")]
        let model = ConsoleViewModel(stores: stores(directory), midiService: midi, outputTransport: output,
                                     initialPreset: .robotArm)
        try await waitUntil { !model.startingMIDI && model.connection.sourceEndpoints.count == 1 }
        model.mcp.service.permissions.deviceControl = true
        let arguments: JSONValue = .object(["sourceID": .number(7), "destinationID": .number(9)])
        let before = model.endpointSelection, choices = midi.choices.count

        model.output.start()
        XCTAssertTrue(model.mcp.service.call("set_midi_endpoints", arguments: arguments).isError)
        XCTAssertTrue(model.output.settings.enabled, "a remote port change must not stop the output")
        model.output.stop()

        model.requestSource(.hardware)
        model.beginLearning(at: .pushEncoder(group: 1, 1))
        XCTAssertTrue(model.isLearning)
        XCTAssertTrue(model.mcp.service.call("set_midi_endpoints", arguments: arguments).isError)
        XCTAssertTrue(model.isLearning, "a remote port change must not end the learn")
        model.stopLearning()

        XCTAssertEqual(model.endpointSelection, before)
        XCTAssertEqual(midi.choices.count, choices)
        XCTAssertFalse(model.mcp.service.call("set_midi_endpoints", arguments: arguments).isError)
    }

    func testIsolatedModeRejectsTheMCPEndpointTool() async {
        let midi = EndpointFakeMIDI()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConsoleViewModel(stores: stores(directory), startsMIDI: false, midiService: midi)
        model.mcp.service.permissions.deviceControl = true
        XCTAssertTrue(model.mcp.service.call("set_midi_endpoints", arguments: .object([
            "sourceID": .null, "destinationID": .null
        ])).isError)
        XCTAssertTrue(midi.choices.isEmpty)
    }

    func testCorruptSettingsPreventStartUntilExplicitlyRepaired() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "midi-endpoints.json")
        let original = Data("{invalid".utf8)
        try original.write(to: url)
        let midi = EndpointFakeMIDI()
        let model = ConsoleViewModel(stores: stores(directory), midiService: midi)
        XCTAssertEqual(midi.starts, 0)
        XCTAssertEqual(model.notice?.level, .error)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(model.endpointSettingsNeedRepair, "an unchanged choice must stay applicable")
        model.applyEndpointSelection(.init())
        XCTAssertFalse(model.endpointSettingsNeedRepair)
        try await waitUntil { !model.startingMIDI }
        XCTAssertEqual(midi.starts, 1)
    }

    func testIsolatedModeCannotConfigureOrStartRealMIDI() async {
        let midi = EndpointFakeMIDI()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConsoleViewModel(stores: stores(directory), startsMIDI: false, midiService: midi)
        model.applyEndpointSelection(.init(destinationID: 3))
        XCTAssertEqual(midi.starts, 0)
        XCTAssertTrue(midi.choices.isEmpty)
        XCTAssertEqual(model.notice?.level, .warning)
    }
}
