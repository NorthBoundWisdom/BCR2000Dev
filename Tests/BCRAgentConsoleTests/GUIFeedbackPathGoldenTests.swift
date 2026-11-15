import BCRAgentCore
import BCRTestSupport
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
final class GUIFeedbackPathGoldenTests: XCTestCase {
    func testRecordedGUIConfirmedConnectAndReconnectSequence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appendingPathComponent("map.json")),
                                   configuration: JSONFileStore(fileURL: directory
                                       .appendingPathComponent("config.json")))
        var map = HardwareMap()
        try map.bind(.encoder(row: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 81))
        try stores.hardwareMap.save(map)
        try stores.configuration.save(.init(name: "Golden", parameters: [
            .init(id: "p", name: "p", minimum: 0, maximum: 127, defaultValue: 10)
        ], assignments: [.init(control: .encoder(row: 1, 1), target: .parameter("p"))]))
        let device = RecordingMIDIService(notifyOnStart: true)
        let model = ConsoleViewModel(stores: stores, midiService: device, automaticallyAdvancesMock: false,
                                     timing: .immediate)
        try await waitUntil { model.pendingHardwareConnection != nil }
        XCTAssertTrue(device.sent.isEmpty)
        model.connectHardware(try XCTUnwrap(model.pendingHardwareConnection).id, mode: .write)
        try await model.waitForBackgroundWork()
        model.setParameter("p", to: 42)
        let route = device.connection
        device.connection = .init()
        device.onConnection?(device.connection)
        XCTAssertEqual(model.source, .mock)
        device.connection = route
        device.onConnection?(route)
        try await waitUntil { model.pendingHardwareConnection != nil }
        XCTAssertEqual(device.sent.count, 2)
        model.connectHardware(try XCTUnwrap(model.pendingHardwareConnection).id, mode: .write)
        try await model.waitForBackgroundWork()
        let output = ["gui_confirmed_connect_reconnect": device.sent.map(\.midi1Bytes)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let path = ProcessInfo.processInfo.environment["BCR_G6_CAPTURE_GUI"] {
            try encoder.encode(output).write(to: URL(fileURLWithPath: path))
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FeedbackOutput/g6-gui.json")
        XCTAssertEqual(output, try JSONDecoder().decode([String: [[UInt8]]].self, from: Data(contentsOf: path)))
    }
}
