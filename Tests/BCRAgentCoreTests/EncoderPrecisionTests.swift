import Foundation
import XCTest
@testable import BCRAgentCore

@MainActor
private final class PrecisionDevice: SurfaceDevice {
    var connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
}

@MainActor
final class EncoderPrecisionTests: XCTestCase {
    private let encoder = BCRControlID.pushEncoder(group: 1, 1)
    private let mirror = BCRControlID.encoder(row: 1, 1)
    private let time = Date(timeIntervalSinceReferenceDate: 900)

    private func configuration(mode: EncoderMode = .absolute, step: Double = 0.5,
                               inverted: Bool = false) -> SurfaceConfiguration
    {
        SurfaceConfiguration(name: "Precision", parameters: [
            .init(id: "angle", name: "Angle", minimum: -180, maximum: 180, defaultValue: 0)
        ], assignments: [
            .init(
                control: encoder,
                target: .parameter("angle"),
                inverted: inverted,
                encoderMode: mode,
                encoderStep: step
            ),
            .init(control: mirror, target: .parameter("angle"))
        ])
    }

    private func session(mode: EncoderMode = .absolute, step: Double = 0.5, inverted: Bool = false) -> SurfaceSession {
        SurfaceSession(
            hardwareDevice: PrecisionDevice(),
            configuration: configuration(mode: mode, step: step, inverted: inverted),
            now: { self.time },
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
    }

    func testRelativeEncodingNeutralSignsMagnitudeAnd14Bit() {
        for maximum: UInt16 in [127, 16383] {
            for mode in [EncoderMode.relative1, .relative2] {
                for delta in [-63, -4, -1, 0, 1, 4, 63] {
                    XCTAssertEqual(
                        mode.delta(value: mode.encoded(delta: delta, maximum: maximum), maximum: maximum),
                        delta
                    )
                }
            }
        }
        XCTAssertEqual(EncoderMode.relative1.encoded(delta: -1, maximum: 127), 127)
        XCTAssertEqual(EncoderMode.relative2.encoded(delta: -1, maximum: 127), 63)
        XCTAssertEqual(EncoderMode.relative2.encoded(delta: 1, maximum: 127), 65)
        XCTAssertEqual(EncoderMode.relative1.delta(value: 64, maximum: 127), -64)
        XCTAssertEqual(EncoderMode.relative1.encoded(delta: Int.min, maximum: 127), 65)
        XCTAssertEqual(EncoderMode.relative2.encoded(delta: Int.max, maximum: 127), 127)
    }

    func testBothRelativeModesMockLoopFineStepsAccelerationAndAbsoluteFeedback() async {
        for mode in [EncoderMode.relative1, .relative2] {
            let s = session(mode: mode)
            s.synchronize()
            s.turn(encoder, by: 1)
            XCTAssertEqual(s.engine.value(of: "angle"), 0.5)
            XCTAssertEqual(s.mock.value(of: encoder), 64)
            XCTAssertEqual(s.mock.value(of: mirror), 64)
            s.turn(encoder, by: 4)
            XCTAssertEqual(s.engine.value(of: "angle"), 2.5)
            s.turn(encoder, by: -1)
            XCTAssertEqual(s.engine.value(of: "angle"), 2)
            s.setParameter("angle", to: 179.75)
            s.turn(encoder, by: 4)
            XCTAssertEqual(s.engine.value(of: "angle"), 180)
            s.turn(encoder, by: -1)
            XCTAssertEqual(s.engine.value(of: "angle"), 179.5)
            XCTAssertEqual(s.mock.value(of: encoder), 127)
        }
    }

    func testRelativeInversionAndModeSwitchPreserveTarget() async throws {
        let s = session(mode: .relative2, inverted: true)
        s.synchronize()
        s.turn(encoder, by: 1)
        XCTAssertEqual(s.engine.value(of: "angle"), -0.5)
        try s.setAssignment(
            .init(control: encoder, target: .parameter("angle"), encoderMode: .relative1, encoderStep: 0.25),
            for: encoder
        )
        s.turn(encoder, by: 1)
        XCTAssertEqual(s.engine.value(of: "angle"), -0.25)
        try s.setAssignment(.init(control: encoder, target: .parameter("angle")), for: encoder)
        s.turn(encoder, by: 1)
        XCTAssertEqual(s.engine.value(of: "angle")!, 180 * 2 * 64 / 127 - 180, accuracy: 1e-9)
    }

    func testNRPNEncodingIsFourCCsAndRejectsInvalidSemanticValues() throws {
        let message = MIDIVoiceMessage.nrpn(channel: 3, number: 0x1234, value: 0x2345)
        XCTAssertEqual(message.midi1Bytes, [0xB3, 99, 0x24, 0xB3, 98, 0x34, 0xB3, 6, 0x46, 0xB3, 38, 0x45])
        let parts = MIDI1UMPCodec.decode(words: try MIDI1UMPCodec.encodeWords(message))
        var assembler = NRPNAssembler()
        let results = parts.compactMap { assembler.consume($0, at: time) }
        XCTAssertEqual(results, [message])
        XCTAssertThrowsError(try MIDI1UMPCodec.encode(message))
        for invalid in [MIDIVoiceMessage.nrpn(channel: 16, number: 0, value: 0),
                        .nrpn(channel: 0, number: 16384, value: 0), .nrpn(channel: 0, number: 0, value: 16384)]
        {
            XCTAssertThrowsError(try MIDI1UMPCodec.encodeWords(invalid))
        }
    }

    func testNRPNAcrossCallbacksChannelsAndSameChannelSelectorReplacement() {
        var a = NRPNAssembler()
        func cc(_ ch: UInt8, _ number: UInt8, _ value: UInt8) -> MIDIVoiceMessage {
            .controlChange(channel: ch, number: number, value: value)
        }
        for message in [cc(0, 99, 1), cc(1, 99, 2), cc(0, 98, 3), cc(1, 98, 4), cc(0, 6, 5), cc(1, 6, 6)] {
            XCTAssertNil(a.consume(message, at: time))
        }
        XCTAssertEqual(a.consume(cc(0, 38, 7), at: time), .nrpn(channel: 0, number: 131, value: 647))
        XCTAssertEqual(a.consume(cc(1, 38, 8), at: time), .nrpn(channel: 1, number: 260, value: 776))
        XCTAssertNil(a.consume(cc(0, 38, 9), at: time))
        XCTAssertNil(a.consume(cc(0, 6, 10), at: time))
        XCTAssertNil(a.consume(cc(0, 99, 11), at: time))
        XCTAssertNil(a.consume(cc(0, 38, 12), at: time))
    }

    func testNRPNIncompleteTimeoutClockResetRPNAndUnrelatedMessages() {
        let parts: [MIDIVoiceMessage] = [
            .controlChange(channel: 0, number: 99, value: 1), .controlChange(channel: 0, number: 98, value: 2),
            .controlChange(channel: 0, number: 6, value: 3)
        ]
        for reset: MIDIVoiceMessage? in [nil, .controlChange(channel: 0, number: 100, value: 0),
                                         .controlChange(channel: 0, number: 101, value: 0),
                                         .controlChange(channel: 0, number: 121, value: 0)]
        {
            var a = NRPNAssembler()
            for p in parts { XCTAssertNil(a.consume(p, at: time)) }
            if let reset { XCTAssertNil(a.consume(reset, at: time)) }
            XCTAssertNil(a.consume(
                .controlChange(channel: 0, number: 38, value: 4),
                at: reset == nil ? time.addingTimeInterval(0.5) : time
            ))
        }
        var a = NRPNAssembler()
        for p in parts { _ = a.consume(p, at: time) }
        _ = a.consume(.controlChange(channel: 0, number: 70, value: 4), at: time.addingTimeInterval(0.4))
        XCTAssertNil(a.consume(.controlChange(channel: 0, number: 38, value: 4), at: time.addingTimeInterval(0.6)))
        for p in parts { _ = a.consume(p, at: time) }
        XCTAssertNil(a.consume(.controlChange(channel: 0, number: 38, value: 4), at: time.addingTimeInterval(-1)))
    }

    func testNRPNMockWireLoopRetainsOneUnitResolutionAndSoftwareFeedback() async throws {
        let s = session()
        try s.setMockNRPN(true, for: encoder)
        s.setParameter("angle", to: -180)
        s.turn(encoder, by: 1)
        XCTAssertEqual(s.engine.value(of: "angle")!, -180 + 360.0 / 16383, accuracy: 1e-10)
        XCTAssertEqual(s.mock.rawValues[encoder], 1)
        XCTAssertEqual(s.events.suffix(5).filter { $0.direction == .input }.count, 4)
        s.setParameter("angle", to: 90)
        XCTAssertEqual(s.mock.rawValues[encoder], 12287)
        s.turn(encoder, by: -1)
        XCTAssertEqual(s.engine.value(of: "angle")!, -180 + 12286.0 / 16383 * 360, accuracy: 1e-10)
        XCTAssertEqual(
            s.mock.value(of: mirror),
            s.engine.configuration.parameter("angle")!.midiValue(for: s.engine.value(of: "angle")!)
        )
    }

    func testNRPNRelativeModesAndActualFeedbackKeepTargetIndependent() async throws {
        for mode in [EncoderMode.relative1, .relative2] {
            let s = session(mode: mode)
            try s.setMockNRPN(true, for: encoder)
            s.turn(encoder, by: -1)
            XCTAssertEqual(s.engine.value(of: "angle"), -0.5)
            s.setLEDFeedbackSource(.actual)
            try s.setActualFeedback(["angle": 0])
            let first = s.mock.rawValues[encoder]
            try s.setActualFeedback(["angle": 0.03])
            XCTAssertNotEqual(s.mock.rawValues[encoder], first)
            XCTAssertEqual(s.engine.value(of: "angle"), -0.5)
            s.turn(encoder, by: 1)
            XCTAssertEqual(s.engine.value(of: "angle"), 0)
            XCTAssertEqual(s.mock.rawValues[encoder], 8193)
        }
    }

    func testNRPNEchoSuppressionUsesAll14Bits() throws {
        let midi = MIDIControlID(kind: .nrpn, channel: 0, number: 700)
        var e = SurfaceEngine(
            hardwareMap: .init(entries: [.init(control: encoder, midi: midi)]),
            configuration: configuration()
        )
        _ = e.setParameter("angle", to: 0, at: time)
        XCTAssertTrue(e.handleInput(.nrpn(channel: 0, number: 700, value: 8192), at: time.addingTimeInterval(0.01))
            .isEmpty)
        _ = e.handleInput(.nrpn(channel: 0, number: 700, value: 8193), at: time.addingTimeInterval(0.02))
        XCTAssertEqual(e.value(of: "angle")!, -180 + 8193.0 / 16383 * 360, accuracy: 1e-10)
    }

    func testValidationAndLegacyMigration() throws {
        var old = try JSONValue.encoded(configuration())
        var raw = old.objectValue!
        raw["version"] = .number(3)
        raw["assignments"] = .array(raw["assignments"]!.arrayValue!.map {
            var assignment = $0.objectValue!
            assignment["encoderMode"] = nil
            assignment["encoderStep"] = nil
            return .object(assignment)
        })
        old = .object(raw)
        let migrated = try old.decoded(SurfaceConfiguration.self).migrated()
        XCTAssertEqual(migrated.version, SurfaceConfiguration.currentVersion)
        XCTAssertEqual(migrated.assignment(for: encoder)?.encoderMode, .absolute)
        for bad in [0.0, -1, .infinity, .nan] {
            var c = configuration()
            XCTAssertThrowsError(try c.assign(.init(
                control: encoder,
                target: .parameter("angle"),
                encoderMode: .relative1,
                encoderStep: bad
            )))
        }
        var c = configuration()
        XCTAssertThrowsError(try c.assign(.init(
            control: .userButton(1),
            target: .parameter("angle"),
            encoderMode: .relative1
        )))
        let map = HardwareMap(
            version: 3,
            entries: [.init(control: encoder, midi: .init(kind: .controlChange, channel: 0, number: 1))]
        )
        XCTAssertEqual(try map.migrated().version, 4)
        XCTAssertThrowsError(try JSONDecoder().decode(
            MIDIControlID.self,
            from: Data(#"{"kind":"nrpn","channel":0,"number":16384}"#.utf8)
        ))
        let identity = MIDIControlID(kind: .nrpn, channel: 15, number: 16383)
        XCTAssertEqual(try JSONDecoder().decode(MIDIControlID.self, from: JSONEncoder().encode(identity)), identity)
    }

    func testNRPNBindingRejectsReservedCCConflictAtomicallyAndDefaultPresetUnchanged() throws {
        var map = HardwareMap()
        try map.bind(encoder, to: .init(kind: .nrpn, channel: 0, number: 1))
        let before = map
        XCTAssertThrowsError(try map.bind(mirror, to: .init(kind: .controlChange, channel: 0, number: 6)))
        XCTAssertEqual(map, before)
        try map.bind(mirror, to: .init(kind: .controlChange, channel: 1, number: 6))
        XCTAssertEqual(HardwareMap.mockPreset().entries.count, 108)
        for (offset, control) in BCRLayout.allControls.enumerated() {
            XCTAssertEqual(
                HardwareMap.mockPreset().midi(for: control),
                .init(kind: .controlChange, channel: 0, number: offset + 1)
            )
        }
    }

    func testNRPNExplicitLearningAcrossCallbacksPersistsAndOrdinaryLearningDoesNotGuess() async throws {
        let device = PrecisionDevice()
        var maps: [HardwareMap] = []
        let s = SurfaceSession(hardwareDevice: device, configuration: configuration(), now: { self.time },
                               saveHardwareMap: { maps.append($0) }, saveConfiguration: { _ in })
        s.selectSource(.hardware)
        XCTAssertTrue(s.beginLearning(at: encoder, format: .nrpn14))
        let wire = MIDI1UMPCodec.decode(words: try MIDI1UMPCodec.encodeWords(.nrpn(
            channel: 2,
            number: 900,
            value: 8192
        )))
        for p in wire.dropLast() { device.onMessages?([p]) }
        XCTAssertNil(s.engine.hardwareMap.midi(for: encoder))
        device.onMessages?([wire.last!])
        XCTAssertEqual(s.engine.hardwareMap.midi(for: encoder), .init(kind: .nrpn, channel: 2, number: 900))
        XCTAssertEqual(maps.count, 1)
        XCTAssertTrue(s.beginLearning(at: mirror))
        device.onMessages?([.controlChange(channel: 1, number: 99, value: 3)])
        XCTAssertEqual(s.engine.hardwareMap.midi(for: mirror), .init(kind: .controlChange, channel: 1, number: 99))
    }

    func testAll14BitPositionsRoundTripWithoutSevenBitLoss() throws {
        let midi = MIDIControlID(kind: .nrpn, channel: 0, number: 1234)
        var engine = SurfaceEngine(hardwareMap: .init(entries: [.init(control: encoder, midi: midi)]),
                                   configuration: configuration())
        engine.echoWindow = 0
        var mock = MockBCR2000(preset: engine.hardwareMap)
        for raw in UInt16(0) ... UInt16(16383) {
            let message = MIDIVoiceMessage.nrpn(channel: 0, number: 1234, value: raw)
            mock.receive(message)
            let effects = engine.handleInput(message, at: time)
            for case let .send(feedback) in effects { mock.receive(feedback) }
            XCTAssertEqual(engine.value(of: "angle")!, -180 + Double(raw) / 16383 * 360, accuracy: 1e-10)
            let output = engine.fullFeedback(at: time)
            for case let .send(feedback) in output { mock.receive(feedback) }
            XCTAssertEqual(mock.rawValues[encoder], raw)
            XCTAssertEqual(mock.value(of: encoder), engine.state(of: encoder).value)
        }
    }

    func testRelativeAssignmentMCPValidationAndFineWriteToNRPNMock() async throws {
        let s = session()
        try s.setMockNRPN(true, for: encoder)
        let service = AgentControlService(session: s)
        service.permissions.configurationWrite = true
        let assignment = ControlAssignment(
            control: encoder,
            target: .parameter("angle"),
            encoderMode: .relative2,
            encoderStep: 0.125
        )
        XCTAssertFalse(service.call("assign_control", arguments: .object(["assignment": try .encoded(assignment)]))
            .isError)
        s.turn(encoder, by: 1)
        XCTAssertEqual(s.engine.value(of: "angle"), 0.125)
        XCTAssertFalse(service.call(
            "set_parameter",
            arguments: .object(["id": .string("angle"), "value": .double(45.125)])
        ).isError)
        XCTAssertEqual(s.mock.rawValues[encoder], UInt16(((45.125 + 180) / 360 * 16383).rounded()))
        var bad = try JSONValue.encoded(assignment).objectValue!
        bad["encoderMode"] = .string("invented")
        XCTAssertTrue(service.call("assign_control", arguments: .object(["assignment": .object(bad)])).isError)
        bad["encoderMode"] = .string("relative2")
        bad["encoderStep"] = .null
        XCTAssertTrue(service.call("assign_control", arguments: .object(["assignment": .object(bad)])).isError)
        XCTAssertEqual(s.engine.configuration.assignment(for: encoder), assignment)
    }

    func testSlowRelativeTicksAccumulateAcrossSnappingAndExternalWritesClearRemainders() async throws {
        for mode in [EncoderMode.relative1, .relative2] {
            let s = session(mode: mode, step: 0.25)
            var definition = s.engine.configuration.parameter("angle")!
            definition.step = 1
            try s.updateParameter(definition)
            for _ in 0 ..< 4 { s.turn(encoder, by: 1) }
            XCTAssertEqual(s.engine.value(of: "angle"), 1)
            for _ in 0 ..< 4 { s.turn(encoder, by: -1) }
            XCTAssertEqual(s.engine.value(of: "angle"), 0)
            s.turn(encoder, by: 1) // pending 0.25
            s.setParameter("angle", to: 10)
            s.turn(encoder, by: 1)
            XCTAssertEqual(s.engine.value(of: "angle"), 10)
            s.turn(encoder, by: 1)
            XCTAssertEqual(s.engine.value(of: "angle"), 10) // 10.5 ties down; old remainder must not leak.
            s.setParameter("angle", to: 180)
            for _ in 0 ..< 20 { s.turn(encoder, by: 1) }
            for _ in 0 ..< 4 { s.turn(encoder, by: -1) }
            XCTAssertEqual(s.engine.value(of: "angle"), 179) // no wind-up at endpoint.
        }
    }

    func testNRPNSoftwareFineAdjustAccumulatesAndAssignmentChangeClearsRemainder() throws {
        let map = HardwareMap(entries: [.init(control: encoder, midi: .init(kind: .nrpn, channel: 0, number: 1000))])
        var config = configuration()
        var definition = config.parameter("angle")!
        definition.step = 1
        try config.updateParameter(definition)
        var engine = SurfaceEngine(hardwareMap: map, configuration: config)
        for _ in 0 ..< 46 { _ = engine.adjust(encoder, by: 1, at: time) }
        XCTAssertEqual(engine.value(of: "angle"), 1)
        for _ in 0 ..< 46 { _ = engine.adjust(encoder, by: -1, at: time) }
        XCTAssertEqual(engine.value(of: "angle"), 0)
        for _ in 0 ..< 20 { _ = engine.adjust(encoder, by: 1, at: time) }
        _ = try engine.assign(.init(control: encoder, target: .parameter("angle")), at: time)
        _ = engine.adjust(encoder, by: 1, at: time)
        XCTAssertEqual(engine.value(of: "angle"), 0)
    }
}
