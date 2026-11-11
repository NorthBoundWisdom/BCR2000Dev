import BCRAgentCore
import Combine
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class RefreshMIDI: MIDIService {
    let connection = MIDIConnectionSnapshot(connectedSource: "fixture", connectedDestination: "fixture")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func start() throws { onConnection?(connection) }
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws {}
}

@MainActor
final class ConsoleRefreshTests: XCTestCase {
    func testHardwareBurstsPublishOnceAndFollowLatestTouchOnNextFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let map = HardwareMap.mockPreset()
        try stores.hardwareMap.save(map)
        let midi = RefreshMIDI()
        let model = ConsoleViewModel(stores: stores, midiService: midi)
        model.selectSource(.hardware)
        model.followsTouch = false
        try await Task.sleep(for: .milliseconds(40))
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        let control = BCRControlID.pushEncoder(group: 2, 3)
        let identity = try XCTUnwrap(map.midi(for: control))
        for value in 1 ... 100 { midi.onMessages?([MIDI1UMPCodec.feedback(control: identity, value: UInt8(value))]) }
        XCTAssertEqual(publications, 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(publications, 1)
        subscription.cancel()
        model.followsTouch = true
        let oldSelection = model.selectedControl
        midi.onMessages?([MIDI1UMPCodec.feedback(control: identity, value: 110)])
        XCTAssertEqual(model.selectedControl, oldSelection)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.selectedControl, control)
        XCTAssertEqual(model.visibleGroup, 2)
    }
}
