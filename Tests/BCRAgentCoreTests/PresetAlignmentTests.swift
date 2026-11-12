import BCRTestSupport
import XCTest
@testable import BCRAgentCore

final class PresetAlignmentTests: XCTestCase {
    private func dump(_ lines: [String]) -> Data {
        BCLFixtures.dump(lines)
    }

    /// A preset like the user's: 56 absolute CC encoders, a few buttons, one sharing an encoder CC.
    private func presetLines(lock: String = "off") -> [String] {
        var lines = ["$rev R1", "$preset", ".name 'Test'", ".snapshot off", ".request off", ".egroups 4",
                     ".fkeys on", ".lock \(lock)", ".init"]
        lines += BCLFixtures.encoderSections {
            [
                ".easypar CC 1 \($0) 0 127 absolute",
                ".showvalue on",
                ".mode 1dot",
                ".resolution 96 96 96 96",
                ".default 0"
            ]
        }
        // Button 6 duplicates encoder 1's identity; 33 is a counter; 34 already reports press/release.
        lines += ["$button 6", ".easypar CC 1 1 127 0 toggleoff", ".showvalue on", ".default 0",
                  "$button 33", ".easypar CC 1 90 127 0 increment 1", ".showvalue on", ".default 0",
                  "$button 34", ".easypar CC 1 91 127 0 toggleoff", ".showvalue on", ".default 0",
                  "$end"]
        return lines
    }

    private func encoderMap() throws -> HardwareMap {
        var map = try BCLFixtures.encoderMap()
        try map.bind(.button(row: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 90),
                     visualizationOnly: true, pressMode: .pulse)
        try map.bind(.button(row: 1, 2), to: .init(kind: .controlChange, channel: 0, number: 91),
                     visualizationOnly: true, pressMode: .momentary)
        return map
    }

    private func configuration() throws -> SurfaceConfiguration {
        var configuration = SurfaceConfiguration.neutral()
        try configuration.addParameter(ParameterDefinition(id: "joint", name: "Joint", unit: "°",
                                                           minimum: -180, maximum: 180, defaultValue: 0))
        try configuration.addParameter(ParameterDefinition(id: "speed", name: "Speed", unit: "%",
                                                           minimum: 0, maximum: 100, defaultValue: 50))
        try configuration.addParameter(ParameterDefinition(id: "raw", name: "Raw", minimum: 0, maximum: 127,
                                                           defaultValue: 0))
        try configuration.assign(ControlAssignment(control: .pushEncoder(group: 1, 1), target: .parameter("joint")))
        try configuration.assign(ControlAssignment(control: .pushEncoder(group: 1, 2), target: .parameter("speed")))
        try configuration.assign(ControlAssignment(control: .pushEncoder(group: 1, 3), target: .parameter("raw")))
        try configuration.assign(ControlAssignment(control: .encoder(row: 1, 1), target: .parameter("joint")))
        return configuration
    }

    func testPlanIsTemporaryAndKeepsEncoderIdentities() throws {
        let plan = try BCRPresetAlignment.prepare(dump: dump(presetLines()), hardwareMap: encoderMap(),
                                                  configuration: configuration())
        XCTAssertEqual(plan.lines.first, "$rev R1")
        XCTAssertEqual(plan.lines.last, "$end")
        XCTAssertFalse(plan.lines
            .contains { $0.hasPrefix("$store") || $0.hasPrefix("$recall") || $0.hasPrefix("$global") })
        // `.init` stays before every element section so it cannot clear written elements.
        let initIndex = try XCTUnwrap(plan.lines.firstIndex(of: ".init"))
        XCTAssertLessThan(initIndex, try XCTUnwrap(plan.lines.firstIndex(of: "$encoder 1")))
        for number in 1 ... 56 {
            XCTAssertTrue(plan.lines.contains(".easypar CC 1 \(number) 0 127 absolute"))
        }
        for (index, frame) in plan.frames(device: 0).enumerated() {
            XCTAssertEqual(Array(frame.prefix(7)), [0xF0, 0, 0x20, 0x32, 0, 0x15, 0x20])
            XCTAssertEqual(Int(frame[7]) * 128 + Int(frame[8]), index)
            XCTAssertTrue(frame.dropFirst().dropLast().allSatisfy { $0 < 0x80 })
        }
    }

    func testMissingAndSharedButtonsGetFreeUniqueIdentities() throws {
        let plan = try BCRPresetAlignment.prepare(dump: dump(presetLines()), hardwareMap: encoderMap(),
                                                  configuration: configuration())
        let buttons = BCRLayout.allControls.filter { !$0.isContinuous }
        XCTAssertEqual(buttons.count, 52)
        let identities = buttons.compactMap { plan.hardwareMap.midi(for: $0) }
        XCTAssertEqual(identities.count, 52)
        let encoders = Set((1 ... 56).map { MIDIControlID(kind: .controlChange, channel: 0, number: UInt8($0)) })
        XCTAssertEqual(Set(identities).count, 52)
        XCTAssertTrue(Set(identities).isDisjoint(with: encoders))
        let shared = BCRControlID.pushEncoderButton(group: 1, 6)
        XCTAssertTrue(plan.changes.contains { $0.kind == .readdressedButton && $0.control == shared })
        XCTAssertEqual(plan.changes.filter { $0.kind == .newButton }.count, 49)
        // New identities only show presses until the user enables functions.
        XCTAssertTrue(plan.hardwareMap.isVisualizationOnly(shared))
        XCTAssertEqual(plan.hardwareMap.pressMode(for: shared), .momentary)
    }

    func testButtonsReportPressAndReleaseInsteadOfCounting() throws {
        let plan = try BCRPresetAlignment.prepare(dump: dump(presetLines()), hardwareMap: encoderMap(),
                                                  configuration: configuration())
        XCTAssertTrue(plan.lines.contains(".easypar CC 1 90 127 0 toggleoff"))
        XCTAssertFalse(plan.lines.contains { $0.contains("increment") })
        XCTAssertEqual(plan.hardwareMap.pressMode(for: .button(row: 1, 1)), .momentary)
        XCTAssertTrue(plan.changes.contains { $0.kind == .buttonBehavior && $0.control == .button(row: 1, 1) })
        XCTAssertFalse(plan.changes.contains { $0.kind == .buttonBehavior && $0.control == .button(row: 1, 2) })
    }

    func testRingModesFollowParameterMeaningOnTopEncodersOnly() throws {
        let plan = try BCRPresetAlignment.prepare(dump: dump(presetLines()), hardwareMap: encoderMap(),
                                                  configuration: configuration())
        XCTAssertEqual(plan.hardwareMap.ringMode(for: .pushEncoder(group: 1, 1)), .pan)
        XCTAssertEqual(plan.hardwareMap.ringMode(for: .pushEncoder(group: 1, 2)), .bar)
        // Unit-less raw values and the lower 24 encoders (dots only) keep the device's mode.
        XCTAssertEqual(plan.hardwareMap.ringMode(for: .pushEncoder(group: 1, 3)), .oneDot)
        XCTAssertEqual(plan.hardwareMap.ringMode(for: .encoder(row: 1, 1)), .oneDot)
        XCTAssertEqual(plan.changes.filter { $0.kind == .ringMode }.count, 2)
    }

    func testLockAndOptionsAreIndependent() throws {
        var options = BCRPresetAlignment.Options()
        options.completeButtons = false; options.ringModes = false; options.buttonBehavior = false
        let plan = try BCRPresetAlignment.prepare(dump: dump(presetLines()), hardwareMap: encoderMap(),
                                                  configuration: configuration(), options: options)
        XCTAssertEqual(plan.changes.map(\.kind), [.lock])
        XCTAssertTrue(plan.lines.contains(".lock on"))
        let locked = try BCRPresetAlignment.prepare(dump: dump(presetLines(lock: "on")), hardwareMap: encoderMap(),
                                                    configuration: configuration(), options: options)
        XCTAssertTrue(locked.isEmpty)
    }

    func testAlignedReadbackNeedsNoFurtherChanges() throws {
        let first = try BCRPresetAlignment.prepare(dump: dump(presetLines()), hardwareMap: encoderMap(),
                                                   configuration: configuration())
        let second = try BCRPresetAlignment.prepare(dump: dump(first.lines), hardwareMap: first.hardwareMap,
                                                    configuration: configuration())
        XCTAssertTrue(second.isEmpty, "\(second.changes)")
        XCTAssertEqual(second.lines, first.lines)
    }

    func testEnablingFunctionsIsExplicit() throws {
        var options = BCRPresetAlignment.Options()
        XCTAssertFalse(options.enableButtonFunctions)
        options.enableButtonFunctions = true
        var configuration = try configuration()
        try configuration.assign(ControlAssignment(
            control: .button(row: 1, 1),
            target: .setParameter(id: "speed", value: 0)
        ))
        let plan = try BCRPresetAlignment.prepare(dump: dump(presetLines()), hardwareMap: encoderMap(),
                                                  configuration: configuration, options: options)
        XCTAssertFalse(plan.hardwareMap.isVisualizationOnly(.button(row: 1, 1)))
        XCTAssertTrue(plan.changes.contains { $0.kind == .enabledFunction && $0.control == .button(row: 1, 1) })
    }

    func testMismatchedEncoderIdentityIsRefusedInsteadOfRewritten() throws {
        var map = try encoderMap()
        try map.bind(.pushEncoder(group: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 120))
        XCTAssertThrowsError(try BCRPresetAlignment.prepare(dump: dump(presetLines()), hardwareMap: map,
                                                            configuration: configuration()))
    }

    func testRejectsStoreOrIncompleteDumps() throws {
        var store = presetLines(); store.insert("$store 1", at: store.count - 1)
        XCTAssertThrowsError(try BCRPresetAlignment.prepare(dump: dump(store), hardwareMap: encoderMap(),
                                                            configuration: configuration()))
        XCTAssertThrowsError(try BCRPresetAlignment.prepare(dump: dump(Array(presetLines().dropLast())),
                                                            hardwareMap: encoderMap(), configuration: configuration()))
    }

    func testBarAndPanRingsFollowTheManual() {
        XCTAssertEqual(LEDRingMode.bar.litLEDs(value: 0), [0])
        XCTAssertEqual(LEDRingMode.bar.litLEDs(value: 127), Set(0 ... 14))
        XCTAssertEqual(LEDRingMode.barOff.litLEDs(value: 0), [])
        XCTAssertEqual(LEDRingMode.pan.litLEDs(value: 64), [7])
        XCTAssertEqual(LEDRingMode.pan.litLEDs(value: 0), Set(0 ... 7))
        XCTAssertEqual(LEDRingMode.pan.litLEDs(value: 127), Set(7 ... 14))
    }
}
