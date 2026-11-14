import BCRTestSupport
import XCTest
@testable import BCRAgentConsole
@testable import BCRAgentCore
@testable import BCRCoreMIDIDriver

private typealias ConfirmationMIDI = RecordingMIDIService

@MainActor
final class HardwareConnectionStatusTests: XCTestCase {
    private func model() throws -> (ConsoleViewModel, ConfirmationMIDI, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        try stores.hardwareMap.save(.mockPreset())
        let midi = ConfirmationMIDI(
            connection: .init(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1"),
            notifyOnStart: true
        )
        let model = ConsoleViewModel(stores: stores, midiService: midi, automaticallyAdvancesMock: false)
        model.mcp.service.permissions.parameterWrite = true
        model.mcp.service.permissions.deviceControl = true
        return (model, midi, directory)
    }

    private func prompt(_ model: ConsoleViewModel) async throws -> HardwareConnectionPrompt {
        try await waitUntil("the connection prompt") { model.pendingHardwareConnection != nil }
        return try XCTUnwrap(model.pendingHardwareConnection, "A connected fake device must offer confirmation")
    }

    private func status(_ model: ConsoleViewModel) throws -> [String: JSONValue] {
        let result = model.mcp.service.call("get_status")
        XCTAssertFalse(result.isError)
        return try XCTUnwrap(result.value.objectValue)
    }

    private func confirmation(_ model: ConsoleViewModel) throws -> JSONValue? {
        try status(model)["hardwareConnection"]?.objectValue?["confirmation"]
    }

    private func requestHardware(_ model: ConsoleViewModel) {
        let result = model.mcp.service.call("set_device_source", arguments: .object(["source": .string("hardware")]))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.value.objectValue?["error"],
                       .string(L10n.text("连接实体设备需要在界面上确认同步方向；确认前保持 Mock。")))
    }

    func testRemoteRequestIsPendingUntilUserConfirmsThenReportsHardware() async throws {
        let (model, midi, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await prompt(model)
        model.declineHardwareConnection(initial.id)
        requestHardware(model)
        XCTAssertEqual(try confirmation(model), .string("pending"), "Include the existing stabilization delay")
        let offered = try await prompt(model)
        XCTAssertEqual(try status(model)["source"], .string("mock"))
        XCTAssertTrue(midi.sent.isEmpty)
        model.connectHardware(offered.id, mode: .write)
        XCTAssertEqual(try confirmation(model), .string("none"))
        XCTAssertEqual(try status(model)["source"], .string("hardware"))
        XCTAssertFalse(midi.sent.isEmpty, "Only the user's confirmation permits fake-device feedback")
    }

    func testDeclineRemainsQueryableAndANewRequestReplacesIt() async throws {
        let (model, midi, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await prompt(model)
        model.declineHardwareConnection(initial.id)
        requestHardware(model)
        let offered = try await prompt(model)
        XCTAssertEqual(try confirmation(model), .string("pending"))
        model.declineHardwareConnection(offered.id)
        XCTAssertEqual(try confirmation(model), .string("declined"))
        XCTAssertEqual(try status(model)["source"], .string("mock"))
        XCTAssertTrue(midi.sent.isEmpty)
        requestHardware(model)
        XCTAssertEqual(try confirmation(model), .string("pending"))
        let next = try await prompt(model)
        model.declineHardwareConnection(offered.id)
        XCTAssertEqual(try confirmation(model), .string("pending"), "Ignore stale dialog callbacks")
        model.declineHardwareConnection(next.id)
    }

    func testDeclineDoesNotSurviveDisconnectOrExplicitSourceSelection() async throws {
        let (model, midi, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        let offered = try await prompt(model)
        model.declineHardwareConnection(offered.id)
        XCTAssertEqual(try confirmation(model), .string("declined"))
        let route = midi.connection
        midi.connection = MIDIConnectionSnapshot()
        midi.onConnection?(midi.connection)
        XCTAssertEqual(try confirmation(model), .string("none"))
        midi.connection = route
        midi.onConnection?(route)
        let next = try await prompt(model)
        XCTAssertEqual(try confirmation(model), .string("pending"))
        model.declineHardwareConnection(next.id)
        model.requestSource(.mock)
        XCTAssertEqual(try confirmation(model), .string("none"))
        XCTAssertTrue(midi.sent.isEmpty)
    }
}
