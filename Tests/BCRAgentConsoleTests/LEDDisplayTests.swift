import XCTest
@testable import BCRAgentConsole
@testable import BCRAgentCore

final class BCRDisplayModelTests: XCTestCase {
    func testRendersLikeTheFourDigitDisplay() {
        // Observed on firmware 1.10: preset 1 shows "P- 1".
        XCTAssertEqual(BCRDisplayModel.text(for: .preset(1)), "P- 1")
        XCTAssertEqual(BCRDisplayModel.text(for: .preset(32)), "P-32")
        XCTAssertEqual(BCRDisplayModel.text(for: .value(7)), "   7")
        XCTAssertEqual(BCRDisplayModel.text(for: .value(127)), " 127")
        // Values of 10000 and above lose their leading 1 on the device.
        XCTAssertEqual(BCRDisplayModel.text(for: .value(12345)), "2345")
        XCTAssertEqual(BCRDisplayModel.text(for: .on), "  on")
        XCTAssertEqual(BCRDisplayModel.text(for: .off), " oFF")
        XCTAssertEqual(BCRDisplayModel.text(for: .unknown), "----")
    }

    func testValueIsShownBrieflyThenReturnsToPreset() {
        var display = BCRDisplayModel(preset: 8)
        XCTAssertEqual(display.content(at: 0), .preset(8))
        display.encoderMoved(rawValue: 64, showsValue: true, at: 10)
        XCTAssertEqual(display.content(at: 10.5), .value(64))
        XCTAssertEqual(display.content(at: 10 + BCRDisplayModel.holdSeconds), .preset(8))
    }

    func testButtonsShowOnAndOffAndCountersShowTheirValue() {
        var display = BCRDisplayModel()
        display.buttonChanged(pressed: true, rawValue: 127, showsValue: true, at: 0)
        XCTAssertEqual(display.content(at: 0.1), .on)
        display.buttonChanged(pressed: false, rawValue: 0, showsValue: true, at: 0.2)
        XCTAssertEqual(display.content(at: 0.3), .off)
        display.buttonChanged(pressed: nil, rawValue: 5, showsValue: true, at: 1)
        XCTAssertEqual(display.content(at: 1.1), .value(5))
        XCTAssertEqual(display.content(at: 5), .unknown)
    }

    func testShowValueOffLeavesTheDisplayUnchanged() {
        var display = BCRDisplayModel(preset: 3)
        display.encoderMoved(rawValue: 99, showsValue: false, at: 0)
        display.buttonChanged(pressed: true, rawValue: 127, showsValue: false, at: 0)
        XCTAssertEqual(display.content(at: 0.1), .preset(3))
    }

    private func dump(_ lines: [String]) -> Data {
        Data(lines.enumerated().flatMap { i, line in
            [0xF0, 0, 0x20, 0x32, 0, 0x15, 0x20, UInt8(i >> 7), UInt8(i & 127)] + Array(line.utf8) + [0xF7]
        })
    }

    func testPresetNumberComesFromAUniqueName() {
        let memory = (1 ... 32).map { $0 == 1 ? "Reason Redrum 1         " : "Preset \($0)" }
        XCTAssertEqual(BCRPresetNames(temporary: "Reason Redrum 1         ", memory: memory).presetNumber, 1)
        XCTAssertEqual(BCRPresetNames(temporary: "Reason Redrum 1", memory: memory).temporaryName, "Reason Redrum 1")
        // Unknown, duplicated or blank names leave the number unknown instead of guessing.
        XCTAssertNil(BCRPresetNames(temporary: "Other", memory: memory).presetNumber)
        XCTAssertNil(BCRPresetNames(temporary: "Same", memory: ["Same", "Same"]).presetNumber)
        XCTAssertNil(BCRPresetNames(temporary: "      ", memory: ["      "]).presetNumber)
    }

    func testProfileReadsNameAndShowValueFromThePreset() throws {
        let lines = ["$rev R1", "$preset", ".name 'Reason Redrum 1         '", ".egroups 4",
                     "$encoder 1", ".easypar CC 1 1 0 127 absolute", ".showvalue on",
                     "$encoder 33", ".easypar CC 1 2 0 127 absolute",
                     "$button 1", ".easypar CC 16 0 127 0 toggleoff", ".showvalue off",
                     "$button 49", ".easypar CC 16 9 127 0 toggleoff", ".showvalue on",
                     "$end"]
        let dump = Data(lines.enumerated().flatMap { i, line in
            [0xF0, 0, 0x20, 0x32, 0, 0x15, 0x20, UInt8(i >> 7), UInt8(i & 127)] + Array(line.utf8) + [0xF7]
        })
        let profile = try BCRDisplayProfile.read(fromPresetDump: dump)
        XCTAssertEqual(profile.name, "Reason Redrum 1")
        XCTAssertTrue(profile.showsValue(.pushEncoder(group: 1, 1)))
        // `.easypar` without a later `.showvalue on` leaves the display off, as on the device.
        XCTAssertFalse(profile.showsValue(.encoder(row: 1, 1)))
        XCTAssertFalse(profile.showsValue(.pushEncoderButton(group: 1, 1)))
        XCTAssertTrue(profile.showsValue(.userButton(1)))
        // Elements without a section keep the device default.
        XCTAssertTrue(profile.showsValue(.encoder(row: 3, 8)))
    }
}

@MainActor
final class LEDDisplayTests: XCTestCase {
    func testMockInputShowsItsValueThenUnknownPreset() async throws {
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false, initialPreset: .robotArm)
        let knob = BCRControlID.encoder(row: 1, 1)
        XCTAssertEqual(model.displayText, "----")
        model.turn(knob, by: 5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.displayText.trimmingCharacters(in: .whitespaces), String(model.displayValue(of: knob)))
        model.press(.button(row: 1, 1))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.displayText, "  on")
        model.release(.button(row: 1, 1))
        try await Task.sleep(for: .milliseconds(1_600))
        // The device never reports its preset, so nothing is guessed.
        XCTAssertEqual(model.displayText, "----")
    }

    func testSourceChangeClearsDisplayedValue() async throws {
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false, initialPreset: .robotArm)
        model.turn(.encoder(row: 1, 1), by: 5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotEqual(model.displayText, "----")
        model.selectSource(.hardware)
        XCTAssertEqual(model.displayText, "----")
    }
}

@MainActor
private final class DisplayDevice: MIDIService {
    var connection = MIDIConnectionSnapshot(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var supportsStartupConfiguration: Bool { true }
    var temporary: Data
    var names: BCRPresetNames
    var writes = 0
    init(temporary: Data, names: BCRPresetNames) { self.temporary = temporary; self.names = names }
    func start() throws {}
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws {}
    func readCurrentPreset() async throws -> Data { temporary }
    func readPresetNames() async throws -> BCRPresetNames { names }
    func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws { writes += 1
    }
}

@MainActor
final class DeviceDisplayTests: XCTestCase {
    private func dump(_ lines: [String]) -> Data {
        Data(lines.enumerated().flatMap { i, line in
            [0xF0, 0, 0x20, 0x32, 0, 0x15, 0x20, UInt8(i >> 7), UInt8(i & 127)] + Array(line.utf8) + [0xF7]
        })
    }

    func testHardwareModeReadsPresetNumberAndShowValueWithoutWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        var map = HardwareMap()
        let knob = BCRControlID.pushEncoder(group: 1, 1), push = BCRControlID.pushEncoderButton(group: 1, 1)
        try map.bind(knob, to: .init(kind: .controlChange, channel: 0, number: 8))
        try map.bind(push, to: .init(kind: .controlChange, channel: 15, number: 0), visualizationOnly: true,
                     pressMode: .momentary)
        try stores.hardwareMap.save(map)
        let preset = dump(["$rev R1", "$preset", ".name 'Redrum'", "$encoder 1", ".easypar CC 1 8 0 127 absolute",
                           ".showvalue on", "$button 1", ".easypar CC 16 0 127 0 toggleoff", ".showvalue off", "$end"])
        let names = BCRPresetNames(temporary: "Redrum", memory: ["Redrum"] + (2 ... 32).map { "P\($0)" })
        let device = DisplayDevice(temporary: preset, names: names)
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.displayText, "P- 1")
        XCTAssertEqual(model.displayPresetName, "Redrum")
        XCTAssertEqual(device.writes, 0)
        // P1 PUSH has ShowValue off on the device: nothing changes.
        device.onMessages?([.controlChange(channel: 15, number: 0, value: 127)])
        XCTAssertEqual(model.displayText, "P- 1")
        device.onMessages?([.controlChange(channel: 0, number: 8, value: 64)])
        XCTAssertEqual(model.displayText, "  64")
        try await Task.sleep(for: .seconds(BCRDisplayModel.holdSeconds + 0.1))
        XCTAssertEqual(model.displayText, "P- 1")
    }

    func testUnknownPresetNameIsNotGuessed() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let preset = dump(["$rev R1", "$preset", ".name 'Edited'", "$end"])
        let device = DisplayDevice(temporary: preset, names: BCRPresetNames(temporary: "Edited",
                                                                            memory: (1 ... 32).map { "P\($0)" }))
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.displayText, "----")
        XCTAssertEqual(model.displayPresetName, "Edited")
    }
}
