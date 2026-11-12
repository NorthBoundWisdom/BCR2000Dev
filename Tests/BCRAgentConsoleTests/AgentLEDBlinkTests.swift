import BCRTestSupport
import XCTest
@testable import BCRAgentConsole
@testable import BCRAgentCore
@testable import BCRConfigurationAdapter
@testable import BCRCoreMIDIDriver

private typealias BlinkMIDI = RecordingMIDIService

final class AgentLEDBlinkPatternTests: XCTestCase {
    func testStatesMapToDistinctRhythms() {
        XCTAssertEqual(BCRIndicatorBlink.pattern(for: .idle), .steady(on: false))
        XCTAssertEqual(BCRIndicatorBlink.pattern(for: .active), .steady(on: true))
        XCTAssertEqual(BCRIndicatorBlink.pattern(for: .queued), .blink(period: 1.2))
        XCTAssertEqual(BCRIndicatorBlink.pattern(for: .attention), .blink(period: 0.4))
        XCTAssertEqual(BCRIndicatorBlink.pattern(for: .fault), .blink(period: 0.2))
        let fast = BCRIndicatorBlink.blink(period: 0.4)
        XCTAssertTrue(fast.isOn(at: 0.1))
        XCTAssertFalse(fast.isOn(at: 0.3))
        XCTAssertTrue(fast.isOn(at: 0.5))
    }
}

@MainActor
final class AgentLEDBlinkTests: XCTestCase {
    private func model() throws -> (ConsoleViewModel, BlinkMIDI, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        var map = HardwareMap()
        try map.bind(.button(row: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 65))
        try stores.hardwareMap.save(map)
        let midi = BlinkMIDI(connection: .init(
            connectedSource: "BCR2000 Port 1",
            connectedDestination: "BCR2000 Port 1"
        ))
        let model = ConsoleViewModel(stores: stores, midiService: midi, initialPreset: .robotArm,
                                     automaticallyAdvancesMock: false)
        model.selectSource(.hardware)
        return (model, midi, directory)
    }

    private func slots(_ state: AgentRunState, in model: ConsoleViewModel) -> [AgentSlot] {
        model.slots.map { slot in
            guard slot.id == AgentSlotID(1) else { return slot }
            var changed = slot
            changed.state = state
            return changed
        }
    }

    private func led(_ midi: BlinkMIDI) -> [UInt8] {
        midi.sent.compactMap { if case let .controlChange(0, 65, value) = $0 { value } else { nil } }
    }

    func testBlinkingIsOptInAndPersisted() throws {
        let (model, _, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(model.blinksAgentLEDs)
        model.setBlinksAgentLEDs(true)
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let reopened = ConsoleViewModel(
            stores: stores,
            midiService: BlinkMIDI(connection: .init(
                connectedSource: "BCR2000 Port 1",
                connectedDestination: "BCR2000 Port 1"
            )),
            initialPreset: .robotArm,
            automaticallyAdvancesMock: false
        )
        XCTAssertTrue(reopened.blinksAgentLEDs)
    }

    func testAttentionBlinksOnAndOffThenSteadyStateStopsTraffic() async throws {
        let (model, midi, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setBlinksAgentLEDs(true)
        midi.sent.removeAll()
        model.applyAgentSlots(slots(.waitingApproval, in: model), changed: AgentSlotID(1))
        try await Task.sleep(for: .milliseconds(700))
        let blinking = led(midi)
        XCTAssertTrue(blinking.contains(127))
        XCTAssertTrue(blinking.contains(0))
        XCTAssertTrue(blinking.allSatisfy { $0 == 0 || $0 == 127 })
        model.applyAgentSlots(slots(.running, in: model), changed: AgentSlotID(1))
        XCTAssertEqual(led(midi).last, 127)
        midi.sent.removeAll()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(led(midi).isEmpty, "steady state must not keep sending")
    }

    func testDisabledKeepsOriginalLevels() throws {
        let (model, midi, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        midi.sent.removeAll()
        model.applyAgentSlots(slots(.waitingApproval, in: model), changed: AgentSlotID(1))
        XCTAssertEqual(led(midi).last, AgentRunState.waitingApproval.feedbackValue)
    }
}
