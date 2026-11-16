@testable import BCRFoundation
@testable import BCRCodexAdapter
@testable import BCRSurfaceDomain
@testable import BCRExamples
@testable import BCRConfigurationAdapter
@testable import BCRMCPAdapter
@testable import BCRHTTPTransport
@testable import BCRCoreMIDIDriver
@testable import BCRPersistenceAdapter
import BCRTestSupport
import XCTest
@testable import BCRAgentConsole

private typealias PressMIDI = RecordingMIDIService

@MainActor
final class HardwarePressAnimationTests: XCTestCase {
    func testMomentaryPressHoldsAndReleaseOnlyReturnsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let push = BCRControlID.pushEncoderButton(group: 1, 1)
        var map = HardwareMap()
        try map.bind(
            push,
            to: .init(kind: .controlChange, channel: 15, number: 0),
            visualizationOnly: true,
            pressMode: .momentary
        )
        try stores.hardwareMap.save(map)
        let midi = PressMIDI()
        let clock = ManualHostTime()
        let model = ConsoleViewModel(stores: stores, midiService: midi,
                                     timing: .init(work: .immediate, presentation: clock.time))
        model.selectSource(.hardware)
        midi.onMessages?([.controlChange(channel: 15, number: 0, value: 127)])
        clock.advance(by: 0.24)
        XCTAssertTrue(model.presentation(of: push).hardwarePressed)
        midi.onMessages?([.controlChange(channel: 15, number: 0, value: 0)])
        XCTAssertFalse(model.presentation(of: push).hardwarePressed)
        clock.advance(by: 0.1)
        try await model.waitForBackgroundWork()
        XCTAssertFalse(model.presentation(of: push).hardwarePressed)
        // A very short tap still appears once, with no second depression on release.
        midi.onMessages?([
            .controlChange(channel: 15, number: 0, value: 127),
            .controlChange(channel: 15, number: 0, value: 0)
        ])
        XCTAssertTrue(model.presentation(of: push).hardwarePressed)
        try await waitUntil { clock.pendingDeadlines.contains(clock.now + 0.08) }
        clock.advance(by: 0.08)
        try await waitUntil("the short tap to release") { !model.presentation(of: push).hardwarePressed }
    }

    func testHeldPressIsClearedWhenTheRouteDisappears() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let push = BCRControlID.pushEncoderButton(group: 1, 1)
        var map = HardwareMap()
        try map.bind(push, to: .init(kind: .controlChange, channel: 15, number: 0),
                     visualizationOnly: true, pressMode: .momentary)
        try stores.hardwareMap.save(map)
        let midi = PressMIDI()
        let clock = ManualHostTime()
        let model = ConsoleViewModel(stores: stores, midiService: midi,
                                     timing: .init(work: .immediate, presentation: clock.time))
        model.selectSource(.hardware)
        midi.onMessages?([.controlChange(channel: 15, number: 0, value: 127)])
        XCTAssertTrue(model.hardwarePressedControls.contains(push))
        midi.connection = MIDIConnectionSnapshot()
        midi.onConnection?(midi.connection)
        XCTAssertEqual(model.source, .mock)
        XCTAssertTrue(model.hardwarePressedControls.isEmpty)
    }

    func testHardwareCounterAndZeroPulsesDepressKnobAndButtonWithoutActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let push = BCRControlID.pushEncoderButton(group: 1, 1), pad = BCRControlID.button(row: 1, 1)
        var map = HardwareMap()
        try map.bind(push, to: .init(kind: .controlChange, channel: 15, number: 100), visualizationOnly: true)
        try map.bind(pad, to: .init(kind: .controlChange, channel: 15, number: 101), visualizationOnly: true)
        try stores.hardwareMap.save(map)
        let midi = PressMIDI()
        let clock = ManualHostTime()
        let model = ConsoleViewModel(stores: stores, midiService: midi,
                                     timing: .init(work: .immediate, presentation: clock.time))
        model.selectSource(.hardware)
        midi.onMessages?([.controlChange(channel: 15, number: 100, value: 1)])
        XCTAssertTrue(model.presentation(of: .pushEncoder(group: 1, 1)).hardwarePressed)
        XCTAssertTrue(model.presentation(of: push).hardwarePressed)
        midi.onMessages?([.controlChange(channel: 15, number: 101, value: 0)])
        XCTAssertTrue(model.presentation(of: pad).hardwarePressed)
        XCTAssertTrue(model.slots.allSatisfy { $0.state == .idle })
        XCTAssertTrue(midi.sent.isEmpty)
        try await waitUntil { clock.pendingDeadlines.contains(0.18) }
        clock.advance(by: 0.18)
        try await waitUntil("both pulses to release") {
            !model.presentation(of: push).hardwarePressed && !model.presentation(of: pad).hardwarePressed
        }
    }
}
