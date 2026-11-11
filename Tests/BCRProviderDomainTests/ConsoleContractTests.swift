import BCRFoundation
import BCRSurfaceDomain
import Foundation
import XCTest

@MainActor
private final class ConsoleDeviceFixture: SurfaceDevice {
    var connection = MIDIConnectionSnapshot(connectedSource: "fixture", connectedDestination: "fixture")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
}

@MainActor
final class ConsoleContractTests: XCTestCase {
    func testSoftwareAndMockInputsRemainDistinctAndNoOutputIsAUserInput() throws {
        let session = SurfaceSession(
            hardwareDevice: ConsoleDeviceFixture(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        session.withWriteOrigin(.agent) { session.turn(.pushEncoder(group: 1, 1), by: 10) }
        let batch = try session.inputEvents.read(generation: nil)
        let events = try XCTUnwrap(batch.objectValue?["events"]?.arrayValue)
        let input = try XCTUnwrap(events.first { $0.objectValue?["kind"] == .string("control.input") }?.objectValue)
        XCTAssertEqual(input["source"], .string("mock"))
        XCTAssertEqual(input["payload"]?.objectValue?["origin"], .string("agent"))
        XCTAssertTrue(events.filter { $0.objectValue?["kind"]?.stringValue?.hasPrefix("feedback.") == true }
            .allSatisfy { $0.objectValue?["payload"]?.objectValue?["accepted"] == .bool(false) })
    }

    func testAbsoluteToggleCrossesThresholdDespiteFeedbackSnappingAtEveryTick() throws {
        let control = BCRControlID.pushEncoder(group: 1, 1)
        let definition = ParameterDefinition(
            id: "generic.toggle",
            name: "Toggle",
            minimum: 0,
            maximum: 1,
            kind: .toggle
        )
        let config = SurfaceConfiguration(
            name: "fixture",
            parameters: [definition],
            assignments: [.init(control: control, target: .parameter(definition.id))]
        )
        let session = SurfaceSession(
            hardwareDevice: ConsoleDeviceFixture(),
            configuration: config,
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        session.synchronize()
        for _ in 0 ..< 70 { session.turn(control, by: 1) }
        XCTAssertEqual(session.engine.value(of: definition.id), 1)
        XCTAssertEqual(session.mock.value(of: control), 127)
        for _ in 0 ..< 70 { session.turn(control, by: -1) }
        XCTAssertEqual(session.engine.value(of: definition.id), 0)
        XCTAssertEqual(session.mock.value(of: control), 0)
    }

    func testEpochChangesAndOldCursorCannotReplayAfterSourceOrMappingChange() throws {
        let session = SurfaceSession(
            hardwareDevice: ConsoleDeviceFixture(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let old = session.inputEvents.generation
        session.selectSource(.hardware)
        XCTAssertNotEqual(session.inputEvents.generation, old)
        XCTAssertThrowsError(try session.inputEvents.read(generation: old))
        let hardware = session.inputEvents.generation
        try session.setAssignment(
            .init(control: .encoder(row: 1, 1), target: .parameter("general.1")),
            for: .encoder(row: 1, 1)
        )
        XCTAssertNotEqual(session.inputEvents.generation, hardware)
    }

    func testDiagnosticFramesAreReadbackNotOperatorEventsAndCannotChangeParameters() throws {
        let device = ConsoleDeviceFixture()
        let session = SurfaceSession(
            hardwareDevice: device,
            hardwareMap: .mockPreset(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        session.selectSource(.hardware)
        let token = try session.beginDiagnosticReadback()
        let generation = session.inputEvents.generation
        let midi = try XCTUnwrap(session.engine.hardwareMap.midi(for: .pushEncoder(group: 1, 1)))
        device.onMessages?([.controlChange(channel: midi.channel, number: UInt8(midi.number), value: 127)])
        XCTAssertEqual(session.engine.value(of: "general.1"), 0)
        let batch = try session.inputEvents.read(generation: generation)
        let entries = try XCTUnwrap(batch.objectValue?["events"]?.arrayValue)
        XCTAssertFalse(entries.contains { $0.objectValue?["kind"] == .string("control.input") })
        XCTAssertTrue(entries.contains { $0.objectValue?["payload"]?.objectValue?["origin"] == .string("readback") })
        XCTAssertThrowsError(try session.endDiagnosticReadback(token: "foreign"))
        try session.endDiagnosticReadback(token: token)
        XCTAssertNotEqual(session.inputEvents.generation, generation)
    }

    func testBoundedInventoryPublishesGapInsteadOfSilentlySkipping() throws {
        let journal = ProviderEventJournal(source: .mock, capacity: 2)
        let generation = journal.generation
        for value in 0 ..< 4 { journal.append(kind: "fixture", payload: .number(value)) }
        XCTAssertThrowsError(try journal.read(generation: generation, after: 0)) { error in
            XCTAssertEqual((error as? ProviderDomainError)?.code, "event_gap")
        }
        let initial = try journal.read(generation: nil)
        XCTAssertEqual(initial.objectValue?["reset"], .bool(true))
        XCTAssertEqual(initial.objectValue?["dropped"], .number(2))
        XCTAssertEqual(initial.objectValue?["events"]?.arrayValue?.count, 2)
    }

    func testPageSwitchInputCannotBeAcceptedUnderTheNewPageGeneration() throws {
        let button = BCRControlID.button(row: 2, 1)
        var config = SurfaceConfiguration.neutral()
        try config.addPage(.init(
            id: "other",
            name: "Other",
            assignments: [.init(control: button, target: .parameter("general.2"))]
        ))
        try config.assign(.init(control: button, target: .switchPage("other")))
        let session = SurfaceSession(
            hardwareDevice: ConsoleDeviceFixture(),
            configuration: config,
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let old = session.inputEvents.generation
        session.press(button)
        XCTAssertNotEqual(session.inputEvents.generation, old)
        XCTAssertEqual(session.engine.configuration.activePageID, "other")
        let newEvents = try session.inputEvents.read(generation: session.inputEvents.generation).objectValue?["events"]?
            .arrayValue ?? []
        XCTAssertFalse(newEvents
            .contains {
                $0.objectValue?["kind"] == .string("control.input") && $0.objectValue?["payload"]?
                    .objectValue?["accepted"] == .bool(true)
            })
    }

    func testSynchronousMappingChangeDuringInputCannotPublishOrApplyItAsNewContext() throws {
        let button = BCRControlID.button(row: 2, 1)
        var config = SurfaceConfiguration.neutral()
        try config.addParameter(.init(id: "new.toggle", name: "New", minimum: 0, maximum: 1, kind: .toggle))
        try config.assign(.init(control: button, target: .agentPrimaryAction(AgentSlotID(1))))
        let session = SurfaceSession(
            hardwareDevice: ConsoleDeviceFixture(),
            configuration: config,
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        session.onTriggerAgent = { [weak session] _ in
            do { try session?.setAssignment(.init(control: button, target: .parameter("new.toggle")), for: button) }
            catch { XCTFail("The fixture mapping could not be installed") }
        }
        let old = session.inputEvents.generation
        session.press(button)
        XCTAssertNotEqual(session.inputEvents.generation, old)
        XCTAssertEqual(session.engine.value(of: "new.toggle"), 0)
        let events = try session.inputEvents.read(generation: session.inputEvents.generation).objectValue?["events"]?
            .arrayValue ?? []
        XCTAssertFalse(events.contains { $0.objectValue?["kind"] == .string("control.input") })
    }
}
