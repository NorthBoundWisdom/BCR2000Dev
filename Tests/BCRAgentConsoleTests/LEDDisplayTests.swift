import BCRTestSupport
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

    func testTransfersShowBusyOverEverythingElse() {
        var display = BCRDisplayModel(preset: 1)
        display.encoderMoved(rawValue: 64, showsValue: true, at: 0)
        display.beginTransfer()
        XCTAssertEqual(display.content(at: 0.1), .busy)
        display.beginTransfer(); display.endTransfer()
        XCTAssertEqual(display.content(at: 0.1), .busy)
        display.endTransfer()
        // The value that was showing is not resurrected; the preset number returns.
        XCTAssertEqual(display.content(at: 0.1), .preset(1))
        XCTAssertEqual(Set((0 ..< 24).map {
            BCRDisplayModel.busyFrame(at: Double($0) / BCRDisplayModel.Calibration.busyFramesPerSecond)
        }), Set(0 ..< 12))
    }

    func testBusyAnimationIsClockwiseAndRepeatsFourTimesPerSecond() {
        XCTAssertEqual(BCRDisplayModel.Calibration.busyFrameSequence, Array(0 ..< 12))
        XCTAssertEqual(BCRDisplayModel.Calibration.busyRotationsPerSecond, 4)
        for segment in 0 ..< 12 {
            let time = (Double(segment) + 0.25) / 48
            XCTAssertEqual(BCRDisplayModel.busyFrame(at: time), segment)
            XCTAssertEqual(BCRDisplayModel.busyFrame(at: time + 0.25), segment)
        }
    }

    func testWriteAnimationIsCounterclockwiseAtOneTurnPerSecond() {
        for segment in 0 ..< 12 {
            let time = (Double(segment) + 0.25) / 12
            XCTAssertEqual(BCRDisplayModel.busyFrame(at: time, operation: .write), 11 - segment)
            XCTAssertEqual(BCRDisplayModel.busyFrame(at: time + 1, operation: .write), 11 - segment)
        }
        XCTAssertEqual(BCRDisplayModel.Calibration.framesPerSecond(for: .write), 12)
        XCTAssertEqual(BCRDisplayModel.Calibration.framesPerSecond(for: .read), 48)
    }

    func testOverlappingTransfersKeepTheirDirectionWhenCompletedOutOfOrder() {
        var model = BCRDisplayModel(preset: 1)
        let read = model.beginTransfer(.read), write = model.beginTransfer(.write)
        XCTAssertEqual(model.transferOperation, .write)
        model.endTransfer(read)
        XCTAssertEqual(model.transferOperation, .write)
        XCTAssertEqual(model.transfers, 1)
        model.endTransfer(write)
        XCTAssertEqual(model.transfers, 0)
        XCTAssertEqual(model.content(at: 0), .preset(1))
    }

    func testShowValueOffLeavesTheDisplayUnchanged() {
        var display = BCRDisplayModel(preset: 3)
        display.encoderMoved(rawValue: 99, showsValue: false, at: 0)
        display.buttonChanged(pressed: true, rawValue: 127, showsValue: false, at: 0)
        XCTAssertEqual(display.content(at: 0.1), .preset(3))
    }

    private func dump(_ lines: [String]) -> Data {
        BCLFixtures.dump(lines)
    }

    func testPresetNumberComesFromAUniqueName() {
        let memory = (1 ... 32).map { $0 == 1 ? "Reason Redrum 1         " : "Preset \($0)" }
        XCTAssertEqual(BCRPresetNames(temporary: "Reason Redrum 1         ", memory: memory).presetNumber, 1)
        XCTAssertEqual(BCRPresetNames(temporary: "Reason Redrum 1", memory: memory).temporaryName, "Reason Redrum 1")
        // Unknown, duplicated or blank names leave the number unknown instead of guessing.
        XCTAssertNil(BCRPresetNames(temporary: "Other", memory: memory).presetNumber)
        XCTAssertNil(BCRPresetNames(temporary: "Same", memory: ["Same", "Same"]).presetNumber)
        XCTAssertEqual(BCRPresetNames(temporary: "Same", memory: ["Same", "x", "Same"]).candidates, [1, 3])
        XCTAssertNil(BCRPresetNames(temporary: "      ", memory: ["      "]).presetNumber)
    }

    func testSameNamedPresetsAreResolvedByContentWithoutValues() throws {
        let body = ["$rev R1", "$preset", ".name 'Redrum'", "$encoder 1", ".easypar CC 1 1 0 127 absolute"]
        let temporary = dump(body + [".default 40", "$end"])
        let slot1 = dump(body + [".default 0", "$end"])
        let slot8 = dump(["$rev R1", "$preset", ".name 'Redrum'", "$end"])
        XCTAssertEqual(try BCRPresetNames.resolve(temporary: temporary, candidates: [1: slot1, 8: slot8]), 1)
        // An edited temporary preset (e.g. aligned) matches neither: unknown, not guessed.
        let edited = dump(["$rev R1", "$preset", ".name 'Redrum'", ".lock on", "$end"])
        XCTAssertNil(try BCRPresetNames.resolve(temporary: edited, candidates: [1: slot1, 8: slot8]))
    }

    func testProfileReadsNameAndShowValueFromThePreset() throws {
        let lines = ["$rev R1", "$preset", ".name 'Reason Redrum 1         '", ".egroups 4",
                     "$encoder 1", ".easypar CC 1 1 0 127 absolute", ".showvalue on",
                     "$encoder 33", ".easypar CC 1 2 0 127 absolute",
                     "$button 1", ".easypar CC 16 0 127 0 toggleoff", ".showvalue off",
                     "$button 49", ".easypar CC 16 9 127 0 toggleoff", ".showvalue on",
                     "$end"]
        let dump = BCLFixtures.dump(lines)
        let profile = try BCRDisplayProfile.read(fromPresetDump: dump)
        XCTAssertNil(profile.locked)
        let locked = try BCRDisplayProfile.read(fromPresetDump: self.dump(
            ["$rev R1", "$preset", ".name 'A'", ".lock on", "$end"]
        ))
        XCTAssertEqual(locked.locked, true)
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
    var memory: [Int: Data] = [:]
    var writes = 0
    var dumps = 0
    init(temporary: Data, names: BCRPresetNames) { self.temporary = temporary; self.names = names }
    var dumpDelay = Duration.zero
    var nameReadFails = false
    var memoryReadFails = false
    var memoryReads: [Int] = []
    var nameResponses: [BCRPresetNames] = []
    func configureStartup(_ program: MIDIStartupProgram) async throws {}
    func readMemoryPreset(_ number: Int) async throws -> Data {
        dumps += 1; memoryReads.append(number)
        try await Task.sleep(for: dumpDelay)
        if memoryReadFails { throw CocoaError(.fileReadUnknown) }
        return memory[number] ?? temporary
    }

    func start() throws {}
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws {}
    func readCurrentPreset() async throws -> Data { dumps += 1; try await Task.sleep(for: dumpDelay); return temporary }
    func readPresetNames() async throws -> BCRPresetNames {
        if nameReadFails { throw CocoaError(.fileReadUnknown) }
        if !nameResponses.isEmpty { return nameResponses.removeFirst() }
        return names
    }

    func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws { writes += 1
    }
}

@MainActor
final class DeviceDisplayTests: XCTestCase {
    private func dump(_ lines: [String]) -> Data {
        BCLFixtures.dump(lines)
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
        XCTAssertFalse(model.deviceActivity)
        device.onMessages?([.controlChange(channel: 15, number: 0, value: 127)])
        XCTAssertEqual(model.displayText, "P- 1")
        // The IN indicator flashes for any device message, then clears.
        XCTAssertTrue(model.deviceActivity)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.deviceActivity)
        XCTAssertNil(model.deviceKeysLocked)
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

    func testDuplicateNamesAreResolvedAgainAfterDeviceRecall() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let preset = dump([
            "$rev R1",
            "$preset",
            ".name 'Redrum'",
            "$encoder 1",
            ".easypar CC 1 1 0 127 absolute",
            "$end"
        ])
        let other = dump(["$rev R1", "$preset", ".name 'Redrum'", "$end"])
        var memory = (1 ... 32).map { "P\($0)" }; memory[0] = "Redrum"; memory[7] = "Redrum"
        let device = DisplayDevice(temporary: preset, names: BCRPresetNames(temporary: "Redrum", memory: memory))
        device.memory = [1: preset, 8: other]
        device.dumpDelay = .milliseconds(100)
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(50))
        // While the device dumps (its display animating), the panel shows busy too.
        XCTAssertTrue(model.displayBusy)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(model.displayBusy)
        XCTAssertEqual(model.displayText, "P- 1")
        XCTAssertEqual(device.dumps, 3)
        // A same-named recall cannot be detected from names or the old cache.
        device.temporary = other
        model.selectSource(.mock)
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.displayText, "P- 8")
        XCTAssertEqual(device.dumps, 6)
    }
}

@MainActor
final class LockedPresetDisplayTests: XCTestCase {
    private func model(cachedName: String, locked: Bool = true, cachedPreset: Int? = 1) throws
        -> (ConsoleViewModel, DisplayDevice, URL)
    {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        var map = HardwareMap()
        try map.bind(.pushEncoder(group: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 8))
        try stores.hardwareMap.save(map)
        var profile = BCRDisplayProfile(name: cachedName)
        profile.resolvedPreset = cachedPreset
        profile.resolvedCandidates = [1, 8]
        try JSONFileStore<BCRDisplayProfile>(fileURL: directory.appending(path: "display-profile.json")).save(profile)
        let preset = BCLFixtures.dump([
            "$rev R1",
            "$preset",
            ".name 'Redrum'",
            ".egroups 4",
            locked ? ".lock on" : ".lock off",
            "$encoder 1",
            ".easypar CC 1 8 0 127 absolute",
            ".showvalue on",
            "$end"
        ])
        let device = DisplayDevice(temporary: preset, names: .init(temporary: "Redrum",
                                                                   memory: ["Redrum"] + (2 ... 7)
                                                                       .map { "P\($0)" } + ["Redrum"]))
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        return (model, device, directory)
    }

    private func readLockedPreset(_ model: ConsoleViewModel) async throws {
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(50))
        model.beginPresetAlignment()
        for _ in 0 ..< 100 {
            if model.presetAlignment?.phase == .preview { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Read-only preset preview did not settle")
    }

    func testFreshLockedReadCannotTrustAnAmbiguousCandidateCache() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await readLockedPreset(model)
        XCTAssertEqual(model.deviceKeysLocked, true)
        XCTAssertEqual(model.displayText, "----")
        XCTAssertEqual(device.writes, 0)
        let dumps = device.dumps
        device.onConnection?(device.connection)
        XCTAssertEqual(model.displayText, "----")
        XCTAssertEqual(device.dumps, dumps)
        model.dismissPresetAlignment()
        device.onMessages?([.controlChange(channel: 0, number: 8, value: 100)])
        XCTAssertEqual(model.displayText, " 100")
        try await Task.sleep(for: .seconds(BCRDisplayModel.holdSeconds + 0.1))
        XCTAssertEqual(model.displayText, "----")
    }

    func testLockedReadCannotReuseNumberFromADifferentPresetName() async throws {
        let (model, device, directory) = try model(cachedName: "Other")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await readLockedPreset(model)
        XCTAssertEqual(model.deviceKeysLocked, true)
        XCTAssertNil(model.displayProfile?.resolvedPreset)
        XCTAssertEqual(model.displayText, "----")
        XCTAssertEqual(device.writes, 0)
    }

    func testUnlockedReadCannotTrustAnAmbiguousCandidateCache() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum", locked: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await readLockedPreset(model)
        XCTAssertEqual(model.deviceKeysLocked, false)
        XCTAssertEqual(model.displayText, "----")
        XCTAssertEqual(device.writes, 0)
    }

    func testLockingCannotInventAnUnknownPresetNumber() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum", cachedPreset: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await readLockedPreset(model)
        XCTAssertEqual(model.deviceKeysLocked, true)
        XCTAssertNil(model.displayProfile?.resolvedPreset)
        XCTAssertEqual(model.displayText, "----")
        XCTAssertEqual(device.writes, 0)
    }

    func testNameReadFailureCannotRestoreACachedNumber() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum")
        defer { try? FileManager.default.removeItem(at: directory) }
        device.nameReadFails = true
        try await readLockedPreset(model)
        XCTAssertEqual(model.displayText, "----")
        XCTAssertNil(model.displayProfile?.resolvedPreset)
        model.dismissPresetAlignment()
        try await readLockedPreset(model)
        let saved = try JSONFileStore<BCRDisplayProfile>(fileURL: directory.appending(path: "display-profile.json"))
            .load()
        XCTAssertNil(saved?.resolvedPreset)
        XCTAssertEqual(device.writes, 0)
    }

    func testCorruptProfileIsRebuiltFromFreshDumpWhenNamesFail() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore<BCRDisplayProfile>(fileURL: directory.appending(path: "display-profile.json"))
        try Data("broken json".utf8).write(to: store.fileURL)
        device.nameReadFails = true
        try await readLockedPreset(model)
        let repaired = try XCTUnwrap(store.load())
        XCTAssertEqual(repaired.name, "Redrum")
        XCTAssertEqual(repaired.locked, true)
        XCTAssertNil(repaired.resolvedPreset)
    }

    func testLockedCopyWithoutProofSkipsTheSlowSameNamedSlotDumpsOnConnection() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum", cachedPreset: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        device.memory[1] = device.temporary
        device.memory[8] = BCLFixtures.dump(["$rev R1", "$preset", ".name 'Redrum'", ".lock on", "$end"])
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(250))
        // Connecting reads only names and the working copy; no ~24 s of extra device busy time.
        XCTAssertEqual(model.displayContent, .unknown)
        XCTAssertEqual(device.memoryReads, [])
        XCTAssertEqual(device.writes, 0)
    }

    func testEditedLockedPresetCanUseAnExplicitScreenConfirmationForThisConnection() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum", cachedPreset: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Both memory replies differ from the approved working copy: automatic resolution stays unknown.
        device.memory[1] = BCLFixtures.dump(["$rev R1", "$preset", ".name 'Redrum'", "$end"])
        device.memory[8] = device.memory[1]
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.displayContent, .unknown)
        model.requestPresetNumberConfirmation()
        for _ in 0 ..< 100 {
            if model.pendingPresetNumberConfirmation != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let context = try XCTUnwrap(model.pendingPresetNumberConfirmation)
        model.confirmDisplayPresetNumber(context.id, number: 2)
        XCTAssertEqual(model.displayContent, .unknown)
        XCTAssertNil(model.selectedPresetNumber)
        model.selectDisplayPresetNumber(context.id, number: 1)
        model.selectGroup(2)
        XCTAssertEqual(model.selectedPresetNumber, 1)
        model.confirmDisplayPresetNumber(context.id, number: 1)
        XCTAssertEqual(model.displayContent, .preset(1))
        XCTAssertEqual(model.displayText, "P- 1")
        XCTAssertEqual(device.writes, 0)
        model.selectSource(.mock)
        // A stale confirmation context cannot be reused after the session changed.
        model.confirmDisplayPresetNumber(context.id, number: 1)
        XCTAssertEqual(model.displayContent, .unknown)
        // The fresh working copy is byte-identical on the same route: the confirmed number returns
        // from its definition-bound record, without reading the same-named memory slots again.
        let memoryReads = device.memoryReads
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.displayContent, .preset(1))
        XCTAssertEqual(device.memoryReads, memoryReads)
        XCTAssertEqual(device.writes, 0)
    }

    func testProvenNumberSurvivesARestartOnlyForTheIdenticalWorkingCopy() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum", locked: false, cachedPreset: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        device.memory[1] = device.temporary
        device.memory[8] = BCLFixtures.dump(["$rev R1", "$preset", ".name 'Redrum'", ".lock on", "$end"])
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.displayContent, .preset(1))

        // Same device, same directory, new process: identical copy -> number without memory dumps.
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let sameCopy = DisplayDevice(temporary: device.temporary, names: device.names)
        let restarted = ConsoleViewModel(stores: stores, midiService: sameCopy, initialPreset: .robotArm)
        restarted.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(restarted.displayContent, .preset(1))
        XCTAssertEqual(sameCopy.memoryReads, [])

        // A different definition under the same name is never given the recorded number.
        let edited = BCLFixtures.dump([
            "$rev R1", "$preset", ".name 'Redrum'", ".egroups 4", ".lock on",
            "$encoder 1", ".easypar CC 1 9 0 127 absolute", ".showvalue on", "$end"
        ])
        let otherCopy = DisplayDevice(temporary: edited, names: device.names)
        let other = ConsoleViewModel(stores: stores, midiService: otherCopy, initialPreset: .robotArm)
        other.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(other.displayContent, .unknown)
        XCTAssertEqual(otherCopy.writes, 0)
    }

    func testCorruptNumberRecordsNeverProduceANumber() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum", cachedPreset: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("broken json".utf8).write(to: directory.appending(path: "preset-number-evidence.json"))
        device.memory[1] = BCLFixtures.dump(["$rev R1", "$preset", ".name 'Redrum'", "$end"])
        device.memory[8] = device.memory[1]
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.displayContent, .unknown)
    }

    func testScreenConfirmationRefreshesADumpWhenItsNameNoLongerMatches() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum", cachedPreset: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(100))
        device.names = .init(temporary: "New", memory: ["New"])
        device.temporary = BCLFixtures.dump(["$rev R1", "$preset", ".name 'New'", ".lock on", "$end"])
        model.requestPresetNumberConfirmation()
        for _ in 0 ..< 100 {
            if model.pendingPresetNumberConfirmation != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let context = try XCTUnwrap(model.pendingPresetNumberConfirmation)
        XCTAssertEqual(try BCRDisplayProfile.read(fromPresetDump: context.dump).name, "New")
        model.confirmDisplayPresetNumber(context.id, number: 1)
        XCTAssertEqual(model.displayPresetName, "New")
        XCTAssertEqual(model.displayContent, .preset(1))
    }

    func testLearningInterruptsDisplayReadWithoutAWarning() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum")
        defer { try? FileManager.default.removeItem(at: directory) }
        device.dumpDelay = .milliseconds(150)
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(30))
        model.beginLearning(at: .userButton(1))
        let notice = model.notice
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.notice?.text, notice?.text)
        XCTAssertEqual(model.notice?.level, .info)
        XCTAssertFalse(model.displayBusy)
        model.stopLearning()
    }

    func testChangedCandidateSetAboveLimitClearsOldNumber() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum")
        defer { try? FileManager.default.removeItem(at: directory) }
        device.names = .init(temporary: "Redrum", memory: Array(repeating: "Redrum", count: 5))
        try await readLockedPreset(model)
        XCTAssertEqual(model.displayText, "----")
        XCTAssertNil(model.displayProfile?.resolvedPreset)
        XCTAssertTrue(device.memoryReads.isEmpty)
        XCTAssertEqual(device.writes, 0)
    }

    func testChangedCandidateSetAndFailedResolutionCannotLeaveOldNumber() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum")
        defer { try? FileManager.default.removeItem(at: directory) }
        device.names = .init(temporary: "Redrum", memory: ["Redrum", "Redrum", "Redrum"])
        device.memoryReadFails = true
        try await readLockedPreset(model)
        XCTAssertEqual(model.displayText, "----")
        XCTAssertNil(model.displayProfile?.resolvedPreset)
        XCTAssertEqual(device.writes, 0)
    }

    func testCandidateChangeDuringMemoryResolutionCannotPublishOldResult() async throws {
        let (model, device, directory) = try model(cachedName: "Redrum", locked: false, cachedPreset: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldNames = device.names
        device.nameResponses = [oldNames]
        device.names = .init(temporary: "Redrum", memory: ["Redrum", "Redrum", "Redrum"])
        device.memory[1] = device.temporary
        device.memory[8] = BCLFixtures.dump(["$rev R1", "$preset", ".name 'Redrum'", "$end"])
        model.selectSource(.hardware)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.displayText, "----")
        XCTAssertNil(model.displayProfile?.resolvedPreset)
        XCTAssertEqual(device.memoryReads, [1, 8])
    }

    func testConfiguredNumberCannotOverrideAFreshDifferentPresetName() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let program = try MIDIStartupProgram(preset: 8, presetSettings: [".name 'Old'", ".snapshot off", ".request off",
                                                                         ".egroups 4", ".fkeys on", ".lock off"])
        try JSONFileStore<MIDIStartupProgram>(fileURL: directory.appending(path: "hardware-startup.json")).save(program)
        var map = HardwareMap()
        try map.bind(.pushEncoder(group: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 8))
        try stores.hardwareMap.save(map)
        let data = BCLFixtures.dump(["$rev R1", "$preset", ".name 'New'", ".egroups 4", ".lock on", "$end"])
        let device = DisplayDevice(temporary: data,
                                   names: .init(
                                       temporary: "New",
                                       memory: ["New"] + (2 ... 7).map { "P\($0)" } + ["Old"]
                                   ))
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        for _ in 0 ..< 80 {
            if let prompt = model
                .pendingHardwareConnection { model.connectHardware(prompt.id, mode: .initialize); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.source, .hardware)
        XCTAssertNil(model.startupConfiguredPreset)
        XCTAssertEqual(model.displayText, "P- 1")
        XCTAssertEqual(model.displayPresetName, "New")
    }

    func testConfiguredNumberCannotFollowARenamedMemorySlot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let program = try MIDIStartupProgram(preset: 8, presetSettings: [".name 'Old'", ".snapshot off", ".request off",
                                                                         ".egroups 4", ".fkeys on", ".lock off"])
        try JSONFileStore<MIDIStartupProgram>(fileURL: directory.appending(path: "hardware-startup.json")).save(program)
        var map = HardwareMap()
        try map.bind(.pushEncoder(group: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 8))
        try stores.hardwareMap.save(map)
        let data = BCLFixtures.dump(["$rev R1", "$preset", ".name 'New'", ".egroups 4", ".lock on", "$end"])
        let device = DisplayDevice(temporary: data,
                                   names: .init(
                                       temporary: "New",
                                       memory: ["New"] + (2 ... 7).map { "P\($0)" } + ["New"]
                                   ))
        device.memoryReadFails = true
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        for _ in 0 ..< 80 {
            if let prompt = model
                .pendingHardwareConnection { model.connectHardware(prompt.id, mode: .initialize); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.source, .hardware)
        XCTAssertNil(model.startupConfiguredPreset)
        XCTAssertEqual(model.displayText, "----")
    }

    func testConfiguredNumberCannotDistinguishSameNamedSlots() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let program = try MIDIStartupProgram(preset: 8, presetSettings: [".name 'Old'", ".snapshot off", ".request off",
                                                                         ".egroups 4", ".fkeys on", ".lock off"])
        try JSONFileStore<MIDIStartupProgram>(fileURL: directory.appending(path: "hardware-startup.json")).save(program)
        var map = HardwareMap()
        try map.bind(.pushEncoder(group: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 8))
        try stores.hardwareMap.save(map)
        let data = BCLFixtures.dump(["$rev R1", "$preset", ".name 'Old'", ".egroups 4", ".lock on", "$end"])
        let device = DisplayDevice(temporary: data,
                                   names: .init(
                                       temporary: "Old",
                                       memory: ["Old"] + (2 ... 7).map { "P\($0)" } + ["Old"]
                                   ))
        device.memoryReadFails = true
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        for _ in 0 ..< 80 {
            if let prompt = model
                .pendingHardwareConnection { model.connectHardware(prompt.id, mode: .initialize); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.source, .hardware)
        XCTAssertNil(model.startupConfiguredPreset)
        XCTAssertEqual(model.displayText, "----")
    }

    func testExplicitLockedRecallUsesFreshWorkingCopyWithoutReadingSameNamedSlots() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        let program = try MIDIStartupProgram(preset: 8, presetSettings: [".name 'Old'", ".snapshot off", ".request off",
                                                                         ".egroups 4", ".fkeys on", ".lock on"])
        try JSONFileStore<MIDIStartupProgram>(fileURL: directory.appending(path: "hardware-startup.json")).save(program)
        var map = HardwareMap()
        try map.bind(.pushEncoder(group: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 8))
        try stores.hardwareMap.save(map)
        let data = BCLFixtures.dump(["$rev R1", "$preset", ".name 'Old'", ".egroups 4", ".lock on", "$end"])
        let device = DisplayDevice(temporary: data,
                                   names: .init(
                                       temporary: "Old",
                                       memory: ["Old"] + (2 ... 7).map { "P\($0)" } + ["Old"]
                                   ))
        device.memoryReadFails = true
        let model = ConsoleViewModel(stores: stores, midiService: device, initialPreset: .robotArm)
        for _ in 0 ..< 80 {
            if let prompt = model
                .pendingHardwareConnection { model.connectHardware(prompt.id, mode: .initialize); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.source, .hardware)
        XCTAssertEqual(model.startupConfiguredPreset, 8)
        XCTAssertEqual(model.displayText, "P- 8")
        XCTAssertTrue(device.memoryReads.isEmpty)
    }
}

final class PresetNumberEvidenceTests: XCTestCase {
    func testNumberProofBindsRouteCandidatesDefinitionsAndLockState() throws {
        let route = MIDIConnectionSnapshot(connectedSource: "BCR", connectedDestination: "BCR")
        let names = BCRPresetNames(temporary: "Shared", memory: ["Shared", "Other", "Shared"])
        let lines = ["$rev R1", "$preset", ".name 'Shared'", ".lock on", "$encoder 1", ".default 4", "$end"]
        let dump = BCLFixtures.dump(lines)
        let evidence = try XCTUnwrap(PresetNumberEvidence(number: 1, dump: dump, names: names, route: route))
        XCTAssertTrue(evidence.locked)
        XCTAssertTrue(try evidence.matches(dump, names: names, on: route))
        XCTAssertFalse(evidence.matches(names, on: MIDIConnectionSnapshot()))
        XCTAssertFalse(evidence.matches(.init(temporary: "Shared", memory: ["Shared", "Shared"]), on: route))
        XCTAssertFalse(try evidence.matches(BCLFixtures.dump(lines.map { $0 == ".lock on" ? ".lock off" : $0 }),
                                            names: names, on: route))
        XCTAssertTrue(try evidence.matches(BCLFixtures.dump(lines.map { $0 == ".default 4" ? ".default 90" : $0 }),
                                           names: names, on: route))
    }
}
