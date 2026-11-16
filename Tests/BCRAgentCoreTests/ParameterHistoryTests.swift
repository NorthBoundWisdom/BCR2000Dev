import BCRFoundation
import BCRSurfaceDomain
@testable import BCRMCPAdapter
import Foundation
import XCTest

@MainActor
private final class HistoryDevice: SurfaceDevice {
    var connection = MIDIConnectionSnapshot(connectedSource: "fixture in", connectedDestination: "fixture out")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
}

@MainActor
private final class HistoryFixture {
    let device = HistoryDevice()
    let session: SurfaceSession
    init() {
        let clock = HistoryClock()
        self.clock = clock
        session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(), configuration: Self.configuration,
                                 now: { Date(timeIntervalSinceReferenceDate: clock.value) },
                                 historyTime: .init(now: { clock.value }),
                                 saveHardwareMap: { _ in }, saveConfiguration: { _ in })
    }

    let clock: HistoryClock
    static var configuration: SurfaceConfiguration {
        SurfaceConfiguration(name: "history", parameters: [
            .init(id: "x", name: "X", group: "G", minimum: 0, maximum: 127),
            .init(id: "y", name: "Y", group: "G", minimum: 0, maximum: 127)
        ], assignments: [
            .init(control: .pushEncoder(group: 1, 1), target: .parameter("x")),
            .init(control: .pushEncoder(group: 1, 2), target: .parameter("y"))
        ])
    }
}

@MainActor
private final class HistoryClock { var value = 100.0 }

@MainActor
final class ParameterHistoryTests: XCTestCase {
    func testDragCoalescesByInjectedTimeAndNewWritesInvalidateRedo() async throws {
        let f = HistoryFixture(), s = f.session
        s.setParameter("x", to: 10)
        f.clock.value += 0.1; s.setParameter("x", to: 20)
        f.clock.value += 0.1; s.setParameter("x", to: 30)
        try s.undo()
        XCTAssertEqual(s.engine.value(of: "x"), 0)
        XCTAssertFalse(s.canUndo)
        XCTAssertTrue(s.canRedo)
        try s.redo()
        XCTAssertEqual(s.engine.value(of: "x"), 30)
        f.clock.value += 1; s.setParameter("x", to: 40)
        try s.undo()
        XCTAssertEqual(s.engine.value(of: "x"), 30)
        s.setParameter("y", to: 7)
        XCTAssertFalse(s.canRedo)
        try s.undo()
        XCTAssertEqual(s.engine.value(of: "y"), 0)
        XCTAssertEqual(s.engine.value(of: "x"), 30)
    }

    func testWindowInputSourceAndNoOpBoundaries() async throws {
        let f = HistoryFixture(), s = f.session
        s.setParameter("x", to: 10)
        f.clock.value += 1; s.setParameter("x", to: 20)
        s.withWriteOrigin(.agent) { s.setParameter("x", to: 30) }
        try s.undo(); XCTAssertEqual(s.engine.value(of: "x"), 20)
        try s.undo(); XCTAssertEqual(s.engine.value(of: "x"), 10)
        s.setParameter("x", to: 10) // A no-op preserves redo.
        XCTAssertTrue(s.canRedo)
        try s.undo(); XCTAssertEqual(s.engine.value(of: "x"), 0)
        XCTAssertFalse(s.canUndo)
    }

    func testHardwareInputCoalescesAndUndoUsesNormalFeedback() async throws {
        let f = HistoryFixture(), s = f.session
        s.selectSource(.hardware)
        let wire = try XCTUnwrap(s.engine.hardwareMap.midi(for: .pushEncoder(group: 1, 1)))
        f.device.sent.removeAll()
        f.device.onMessages?([wire.message(value: 10)])
        f.clock.value += 0.1; f.device.onMessages?([wire.message(value: 20)])
        try s.undo()
        XCTAssertEqual(s.engine.value(of: "x"), 0)
        XCTAssertEqual(f.device.sent.last, wire.message(value: 0))
        XCTAssertFalse(s.canUndo)
        try s.redo()
        XCTAssertEqual(f.device.sent.last, wire.message(value: 20))
    }

    func testGroupResetAndMCPBatchAreSingleSteps() async throws {
        let f = HistoryFixture(), s = f.session
        s.withParameterHistory { s.setParameter("x", to: 30); s.setParameter("y", to: 40) }
        s.resetGroup("G")
        try s.undo()
        XCTAssertEqual(s.engine.value(of: "x"), 30)
        XCTAssertEqual(s.engine.value(of: "y"), 40)
        let gateway = AgentControlService(session: s)
        let result = gateway.call("set_parameters", arguments: .object(["values": .array([
            .object(["id": .string("x"), "value": .number(70)]),
            .object(["id": .string("y"), "value": .number(80)])
        ])]))
        XCTAssertFalse(result.isError)
        try s.undo()
        XCTAssertEqual(s.engine.value(of: "x"), 30)
        XCTAssertEqual(s.engine.value(of: "y"), 40)
        try s.redo()
        XCTAssertEqual(s.engine.value(of: "x"), 70)
        XCTAssertEqual(s.engine.value(of: "y"), 80)
    }

    func testHistoryRestorationRechecksProtectionAtomicallyAndRetainsEntryOnFailure() async throws {
        for protection in 0 ... 2 {
            let f = HistoryFixture(), s = f.session
            s.withParameterHistory { s.setParameter("x", to: 30); s.setParameter("y", to: 40) }
            var definition = try XCTUnwrap(s.engine.configuration.parameter("y"))
            if protection == 0 { definition.agentWritable = false }
            if protection == 1 { definition.externallyProtected = true }
            try s.updateParameter(definition)
            if protection == 2 { s.setOutputEnableParameter("y") }
            let before = s.engine.parameterValues, count = s.events.count
            XCTAssertThrowsError(try s.undo()) { XCTAssertTrue($0 is ParameterHistoryError) }
            XCTAssertEqual(s.engine.parameterValues, before)
            XCTAssertEqual(s.events.count, count)
            XCTAssertTrue(s.canUndo)
        }
    }

    func testDefinitionsAssignmentsAndMappingsDoNotEnterHistoryAndContextReplacementClearsIt() async throws {
        let f = HistoryFixture(), s = f.session
        var definition = try XCTUnwrap(s.engine.configuration.parameter("x"))
        definition.name = "renamed"
        try s.updateParameter(definition)
        try s.setAssignment(.init(control: .encoder(row: 1, 1), target: .parameter("x")), for: .encoder(row: 1, 1))
        try s.installHardwareMap(.mockPreset())
        XCTAssertFalse(s.canUndo)
        s.setParameter("x", to: 10)
        try s.replaceConfiguration(s.engine.configuration)
        XCTAssertFalse(s.canUndo); XCTAssertFalse(s.canRedo)
        s.setParameter("x", to: 20); s.selectSource(.hardware)
        XCTAssertFalse(s.canUndo); XCTAssertFalse(s.canRedo)
    }

    func testMacroFromMockAndHardwareRestoresAllValuesAsOneStep() async throws {
        for hardware in [false, true] {
            let f = HistoryFixture(), s = f.session
            var config = HistoryFixture.configuration
            try config.addMacro(.init(id: "m", name: "Macro", actions: [.set("x", 25), .set("y", 50)]))

            try s.replaceConfiguration(config)
            try s.setAssignment(.init(control: .button(row: 1, 1), target: .runMacro("m")), for: .button(row: 1, 1))
            if hardware { s.selectSource(.hardware) }
            s.press(.button(row: 1, 1)); s.release(.button(row: 1, 1))
            XCTAssertEqual(s.engine.value(of: "x"), 25)
            XCTAssertEqual(s.engine.value(of: "y"), 50)
            try s.undo()
            XCTAssertEqual(s.engine.value(of: "x"), 0)
            XCTAssertEqual(s.engine.value(of: "y"), 0)
            XCTAssertFalse(s.canUndo)
        }
    }

    func testHistoryIsBoundedAndClockRegressionOrInvalidTimeDoesNotMerge() async {
        var h = ParameterValueHistory()
        for value in 1 ... 60 {
            h.record(before: ["x": Double(value - 1)], after: ["x": Double(value)], key: "x", at: Double(value))
        }
        var count = 0
        while let entry = h.undoEntry {
            count += 1; h.didUndo(actualBefore: entry.after, actualAfter: entry.before)
        }
        XCTAssertEqual(count, ParameterValueHistory.limit)
        h.clear()
        for time in [10.0, 9, .nan, 11] {
            h.record(before: ["x": 0], after: ["x": 1], key: "x", at: time)
        }
        count = 0
        while let entry = h.undoEntry {
            count += 1; h.didUndo(actualBefore: entry.after, actualAfter: entry.before)
        }
        XCTAssertEqual(count, 4)
    }
}

private extension MIDIControlID {
    func message(value: UInt8) -> MIDIVoiceMessage {
        .controlChange(channel: channel, number: UInt8(number), value: value)
    }
}
