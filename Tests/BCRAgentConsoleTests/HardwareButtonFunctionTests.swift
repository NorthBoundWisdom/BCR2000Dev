import BCRTestSupport
import XCTest
@testable import BCRAgentConsole
@testable import BCRAgentCore

private typealias ButtonFunctionMIDI = RecordingMIDIService

@MainActor
final class HardwareButtonFunctionTests: XCTestCase {
    private let enable = BCRControlID.button(row: 2, 1)
    private let agent = BCRControlID.button(row: 1, 1)

    private func model() throws -> (ConsoleViewModel, ButtonFunctionMIDI, ConsoleStores, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        var map = HardwareMap()
        try map.bind(enable, to: .init(kind: .controlChange, channel: 15, number: 11),
                     visualizationOnly: true, pressMode: .momentary)
        try map.bind(agent, to: .init(kind: .note, channel: 15, number: 12),
                     visualizationOnly: true, pressMode: .pulse)
        try stores.hardwareMap.save(map)
        let midi = ButtonFunctionMIDI()
        let model = ConsoleViewModel(stores: stores, midiService: midi, initialPreset: .robotArm,
                                     automaticallyAdvancesMock: false)
        model.selectSource(.hardware)
        return (model, midi, stores, directory)
    }

    private func entry(_ control: BCRControlID, _ model: ConsoleViewModel) throws -> HardwareMapEntry {
        try XCTUnwrap(model.engine.hardwareMap.entries.first { $0.control == control })
    }

    func testEnableOnlyOneButtonPreservesIdentityAndMetadataAndDoesNotSendFeedback() throws {
        let (model, midi, stores, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = model.engine.hardwareMap
        let expected = try entry(enable, model)
        XCTAssertTrue(midi.sent.isEmpty)
        model.setHardwareButtonFunctions(expected, enabled: true)
        let after = model.engine.hardwareMap
        XCTAssertFalse(after.isVisualizationOnly(enable))
        XCTAssertEqual(after.midi(for: enable), expected.midi)
        XCTAssertEqual(after.pressMode(for: enable), expected.pressMode)
        XCTAssertEqual(after.ringMode(for: enable), expected.ringMode)
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(after.entries.filter { $0.control != enable }, before.entries.filter { $0.control != enable })
        XCTAssertEqual(try stores.hardwareMap.load(), after)
        XCTAssertTrue(midi.sent.isEmpty, "Changing the flag must not synchronize or send MIDI")
        midi.onMessages?([.controlChange(channel: 15, number: 11, value: 127)])
        XCTAssertEqual(model.engine.value(of: "arm.enabled"), 1)
        midi.onMessages?([.noteOn(channel: 15, number: 12, velocity: 127)])
        XCTAssertTrue(model.slots.allSatisfy { $0.state == .idle }, "Other preview-only buttons must remain inert")
    }

    func testDisableReturnsToPressOnlyAndPersistsWithoutSendingFeedback() throws {
        let (model, midi, stores, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setHardwareButtonFunctions(try entry(enable, model), enabled: true)
        let enabled = try entry(enable, model)
        model.setHardwareButtonFunctions(enabled, enabled: false)
        XCTAssertTrue(midi.sent.isEmpty)
        midi.onMessages?([.controlChange(channel: 15, number: 11, value: 127)])
        XCTAssertEqual(model.engine.value(of: "arm.enabled"), 0)
        XCTAssertTrue(model.engine.hardwareMap.isVisualizationOnly(enable))
        XCTAssertEqual(try stores.hardwareMap.load(), model.engine.hardwareMap)
        XCTAssertEqual(model.engine.hardwareMap.midi(for: enable), enabled.midi)
    }

    func testStaleConfirmationCannotRecreateAClearedBinding() throws {
        let (model, midi, stores, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try entry(enable, model)
        model.unbind(enable)
        let before = model.engine.hardwareMap
        model.setHardwareButtonFunctions(old, enabled: true)
        XCTAssertEqual(model.engine.hardwareMap, before)
        XCTAssertEqual(try stores.hardwareMap.load(), before)
        XCTAssertEqual(model.notice?.level, .warning)
        XCTAssertTrue(midi.sent.isEmpty)
    }

    func testSourceChangeRejectsConfirmationWithoutChangingPersistedMap() throws {
        let (model, midi, stores, directory) = try model()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try entry(enable, model)
        let before = try stores.hardwareMap.load()
        model.selectSource(.mock)
        model.setHardwareButtonFunctions(old, enabled: true)
        XCTAssertEqual(try stores.hardwareMap.load(), before)
        XCTAssertEqual(model.notice?.level, .warning)
        XCTAssertTrue(midi.sent.isEmpty)
    }
}
