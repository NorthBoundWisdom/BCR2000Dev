import XCTest
@testable import BCRAgentCore

final class SurfaceEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private let joint = ParameterDefinition(id: "j", name: "Joint", minimum: -90, maximum: 90, defaultValue: 0)
    private let enabled = ParameterDefinition(id: "on", name: "On", minimum: 0, maximum: 1, kind: .toggle)

    private func makeEngine(_ assignments: [ControlAssignment]) -> SurfaceEngine {
        SurfaceEngine(
            hardwareMap: .mockPreset(),
            configuration: SurfaceConfiguration(name: "t", parameters: [joint, enabled], assignments: assignments)
        )
    }

    private func midi(_ control: BCRControlID) -> MIDIControlID {
        HardwareMap.mockPreset().midi(for: control)!
    }

    private func sent(_ effects: [SurfaceEffect]) -> [MIDIVoiceMessage] {
        effects.compactMap { if case let .send(message) = $0 { message } else { nil } }
    }

    func testConfigurationReplacementResetsParametersAndPreservesAgentSnapshot() {
        let slot = AgentSlotID(1)
        let control = BCRControlID.button(row: 1, 1)
        var engine = makeEngine([ControlAssignment(control: control, target: .agentPrimaryAction(slot))])
        _ = engine.setParameter("j", to: 90, at: t0)
        _ = engine.setAgentFeedback(slot, value: 96, at: t0)
        engine.beginLearning(control)
        let configuration = engine.configuration
        _ = engine.replaceConfiguration(configuration)
        XCTAssertEqual(engine.value(of: "j"), 0)
        XCTAssertNil(engine.learnTarget)
        XCTAssertEqual(sent(engine.fullFeedback(at: t0)), [
            MIDI1UMPCodec.feedback(control: midi(control), value: 96)
        ])
    }

    func testConfigurationReplacementPreservesDeviceTimingPolicy() {
        var engine = makeEngine([])
        engine.echoWindow = 0
        engine.triggerDebounce = 0.5
        _ = engine.replaceConfiguration(engine.configuration)
        XCTAssertEqual(engine.echoWindow, 0)
        XCTAssertEqual(engine.triggerDebounce, 0.5)
    }

    func testEncoderInputMovesParameterAndMirrorsOnlyToOtherBoundControls() {
        let a = BCRControlID.pushEncoder(group: 1, 1)
        let b = BCRControlID.encoder(row: 1, 1)
        var engine = makeEngine([
            ControlAssignment(control: a, target: .parameter("j")),
            ControlAssignment(control: b, target: .parameter("j"))
        ])

        let effects = engine.handleInput(.controlChange(channel: 0, number: UInt8(midi(a).number), value: 127), at: t0)

        XCTAssertEqual(engine.value(of: "j"), 90)
        XCTAssertEqual(sent(effects), [.controlChange(channel: 0, number: UInt8(midi(b).number), value: 127)])
        XCTAssertEqual(engine.state(of: a).lastInput, 127)
    }

    func testSoftwareParameterChangeWritesEveryBoundControl() {
        let a = BCRControlID.pushEncoder(group: 1, 1)
        var engine = makeEngine([ControlAssignment(control: a, target: .parameter("j"), inverted: true)])

        let effects = engine.setParameter("j", to: 90, at: t0)

        // Inverted: the parameter maximum is the ring minimum.
        XCTAssertEqual(sent(effects), [.controlChange(channel: 0, number: UInt8(midi(a).number), value: 0)])
        XCTAssertEqual(engine.state(of: a).lastOutput, 0)
    }

    func testFeedbackEchoWithinWindowIsIgnored() {
        let a = BCRControlID.pushEncoder(group: 1, 1)
        var engine = makeEngine([ControlAssignment(control: a, target: .parameter("j"))])
        _ = engine.setParameter("j", to: 90, at: t0)

        let echo = MIDIVoiceMessage.controlChange(channel: 0, number: UInt8(midi(a).number), value: 127)
        XCTAssertTrue(engine.handleInput(echo, at: t0.addingTimeInterval(0.05)).isEmpty)
        XCTAssertEqual(engine.state(of: a).lastInput, nil)

        _ = engine.handleInput(
            .controlChange(channel: 0, number: UInt8(midi(a).number), value: 0),
            at: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(engine.value(of: "j"), -90)
    }

    func testToggleButtonFlipsOnPressAndHoldsLEDOnRelease() {
        let button = BCRControlID.button(row: 2, 1)
        var engine = makeEngine([ControlAssignment(control: button, target: .parameter("on"))])
        let number = UInt8(midi(button).number)

        let press = engine.handleInput(.controlChange(channel: 0, number: number, value: 127), at: t0)
        XCTAssertEqual(engine.value(of: "on"), 1)
        XCTAssertEqual(sent(press), [.controlChange(channel: 0, number: number, value: 127)])

        let release = engine.handleInput(
            .controlChange(channel: 0, number: number, value: 0),
            at: t0.addingTimeInterval(0.3)
        )
        XCTAssertEqual(engine.value(of: "on"), 1)
        XCTAssertEqual(sent(release), [.controlChange(channel: 0, number: number, value: 127)])

        _ = engine.handleInput(.controlChange(channel: 0, number: number, value: 127), at: t0.addingTimeInterval(0.6))
        XCTAssertEqual(engine.value(of: "on"), 0)
    }

    func testMomentaryButtonIsOnOnlyWhileHeld() {
        let button = BCRControlID.button(row: 2, 2)
        var engine = makeEngine([ControlAssignment(
            control: button,
            target: .parameter("on"),
            buttonBehavior: .momentary
        )])

        _ = engine.press(button, isDown: true, at: t0)
        XCTAssertEqual(engine.value(of: "on"), 1)
        _ = engine.press(button, isDown: false, at: t0.addingTimeInterval(0.01))
        XCTAssertEqual(engine.value(of: "on"), 0)
    }

    func testAgentButtonTriggersOncePerPressWithDebounceAndShowsAgentLED() {
        let button = BCRControlID.button(row: 1, 3)
        let slot = AgentSlotID(3)
        var engine = makeEngine([ControlAssignment(control: button, target: .agentPrimaryAction(slot))])
        let number = UInt8(midi(button).number)

        let first = engine.handleInput(.controlChange(channel: 0, number: number, value: 127), at: t0)
        XCTAssertTrue(first.contains(.triggerAgent(slot)))
        let bounce = engine.handleInput(
            .controlChange(channel: 0, number: number, value: 127),
            at: t0.addingTimeInterval(0.1)
        )
        XCTAssertFalse(bounce.contains(.triggerAgent(slot)))

        let led = engine.setAgentFeedback(slot, value: 96, at: t0)
        XCTAssertEqual(sent(led), [.controlChange(channel: 0, number: number, value: 96)])
    }

    func testResetGroupReturnsParametersToDefaults() {
        let encoder = BCRControlID.pushEncoder(group: 1, 1)
        let home = BCRControlID.userButton(1)
        let groupedJoint = ParameterDefinition(
            id: "g",
            name: "G",
            group: "arm",
            minimum: 0,
            maximum: 100,
            defaultValue: 25
        )
        var engine = SurfaceEngine(
            hardwareMap: .mockPreset(),
            configuration: SurfaceConfiguration(
                name: "t",
                parameters: [groupedJoint],
                assignments: [
                    ControlAssignment(control: encoder, target: .parameter("g")),
                    ControlAssignment(control: home, target: .resetGroup("arm"))
                ]
            )
        )
        _ = engine.setParameter("g", to: 90, at: t0)

        let effects = engine.press(home, isDown: true, at: t0)

        XCTAssertEqual(engine.value(of: "g"), 25)
        XCTAssertEqual(sent(effects), [.controlChange(channel: 0, number: UInt8(midi(encoder).number), value: 32)])
    }

    func testSoftwareAdjustOfUnassignedEncoderWritesRawRingValue() {
        let encoder = BCRControlID.encoder(row: 3, 8)
        var engine = makeEngine([])

        let effects = engine.adjust(encoder, by: 5, at: t0)

        XCTAssertEqual(sent(effects), [.controlChange(channel: 0, number: UInt8(midi(encoder).number), value: 5)])
    }

    func testSoftwareAdjustStartsFromTheParameterPosition() {
        let encoder = BCRControlID.pushEncoder(group: 1, 1)
        var engine = makeEngine([ControlAssignment(control: encoder, target: .parameter("j"))])

        let effects = engine.adjust(encoder, by: 1, at: t0)

        XCTAssertEqual(sent(effects), [.controlChange(channel: 0, number: UInt8(midi(encoder).number), value: 65)])
    }

    func testUnmappedInputIsReported() {
        var engine = SurfaceEngine(hardwareMap: HardwareMap(), configuration: SurfaceConfiguration(name: "t"))
        XCTAssertEqual(
            engine.handleInput(.controlChange(channel: 3, number: 9, value: 1), at: t0),
            [.unmappedInput(cc(9, channel: 3))]
        )
    }

    // MARK: Learning

    func testLearningBindsAndAdvancesToNextUnboundControlInSection() throws {
        var engine = SurfaceEngine(hardwareMap: HardwareMap(), configuration: SurfaceConfiguration(name: "t"))
        engine.beginLearning(.encoder(row: 1, 1))

        let effects = engine.handleInput(.controlChange(channel: 0, number: 40, value: 70), at: t0)

        XCTAssertTrue(effects.contains(.learned(.encoder(row: 1, 1), cc(40))))
        XCTAssertEqual(engine.hardwareMap.control(for: cc(40)), .encoder(row: 1, 1))
        XCTAssertEqual(engine.learnTarget, .encoder(row: 1, 2))
    }

    func testContinuedMovementOfALearnedEncoderDoesNotBindTheNextControl() {
        var engine = SurfaceEngine(hardwareMap: HardwareMap(), configuration: SurfaceConfiguration(name: "t"))
        engine.beginLearning(.encoder(row: 1, 1))
        _ = engine.handleInput(.controlChange(channel: 0, number: 40, value: 70), at: t0)

        let effects = engine.handleInput(
            .controlChange(channel: 0, number: 40, value: 71),
            at: t0.addingTimeInterval(1)
        )

        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(engine.hardwareMap.boundCount, 1)
        XCTAssertEqual(engine.learnTarget, .encoder(row: 1, 2))
        XCTAssertEqual(engine.state(of: .encoder(row: 1, 1)).lastInput, 71)
    }

    func testButtonLearnsOnPressNotRelease() {
        var engine = SurfaceEngine(hardwareMap: HardwareMap(), configuration: SurfaceConfiguration(name: "t"))
        engine.beginLearning(.button(row: 1, 1))

        XCTAssertTrue(engine.handleInput(.noteOff(channel: 0, number: 60, velocity: 0), at: t0).isEmpty)
        _ = engine.handleInput(.noteOn(channel: 0, number: 60, velocity: 127), at: t0)

        XCTAssertEqual(
            engine.hardwareMap.midi(for: .button(row: 1, 1)),
            MIDIControlID(kind: .note, channel: 0, number: 60)
        )
    }

    func testEncoderLearningRejectsNoteMessagesVisibly() {
        var engine = SurfaceEngine(hardwareMap: HardwareMap(), configuration: SurfaceConfiguration(name: "t"))
        engine.beginLearning(.encoder(row: 1, 1))

        let effects = engine.handleInput(.noteOn(channel: 0, number: 60, velocity: 127), at: t0)

        XCTAssertEqual(
            effects,
            [.learnRejected(.encoder(row: 1, 1), .encoderRequiresControlChange(.encoder(row: 1, 1)))]
        )
        XCTAssertEqual(engine.learnTarget, .encoder(row: 1, 1))
    }

    func testLearningAnAssignedControlImmediatelyWritesSoftwareState() {
        let encoder = BCRControlID.pushEncoder(group: 1, 1)
        var engine = SurfaceEngine(
            hardwareMap: HardwareMap(),
            configuration: SurfaceConfiguration(
                name: "t",
                parameters: [joint],
                assignments: [ControlAssignment(control: encoder, target: .parameter("j"))]
            )
        )
        engine.beginLearning(encoder)

        let effects = engine.handleInput(.controlChange(channel: 2, number: 7, value: 10), at: t0)

        XCTAssertEqual(sent(effects), [.controlChange(channel: 2, number: 7, value: 64)])
        XCTAssertEqual(engine.value(of: "j"), 0, "Learning must not move the parameter")
    }
}
