import Foundation
import XCTest
@testable import BCRAgentCore
@testable import BCRMCPAdapter
@testable import BCRSurfaceDomain

@MainActor
private final class FunctionDevice: SurfaceDevice {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func send(_ message: MIDIVoiceMessage) throws {}
}

@MainActor
private final class FunctionClock {
    var now = Date(timeIntervalSinceReferenceDate: 5_000)
}

@MainActor
final class FunctionSystemTests: XCTestCase {
    private let encoder = BCRControlID.pushEncoder(group: 1, 1)
    private let mirror = BCRControlID.encoder(row: 1, 1)
    private let button = BCRControlID.userButton(1)

    private func session(target: ControlTarget, definition: ParameterDefinition,
                         clock: FunctionClock = FunctionClock()) -> SurfaceSession
    {
        SurfaceSession(hardwareDevice: FunctionDevice(), configuration: SurfaceConfiguration(
            name: "Functions", parameters: [definition], assignments: [
                .init(control: encoder, target: .parameter(definition.id)),
                .init(control: button, target: target)
            ]
        ), now: { clock.now }, saveHardwareMap: { _ in }, saveConfiguration: { _ in })
    }

    func testStepButtonStopsAtLimitAndLEDReportsAvailabilityWhileHeld() async {
        let s = session(target: .stepParameter(id: "x", step: 2, wraps: false),
                        definition: .init(id: "x", name: "X", minimum: 0, maximum: 10, defaultValue: 9))
        s.synchronize()
        XCTAssertEqual(s.mock.value(of: button), 127)
        // No clock advance: Mock feedback must not be mistaken for an input echo.
        s.press(button)
        XCTAssertEqual(s.engine.value(of: "x"), 10)
        XCTAssertEqual(s.mock.value(of: encoder), 127)
        XCTAssertEqual(s.mock.value(of: button), 0)
        s.release(button)
        XCTAssertEqual(s.mock.value(of: button), 0)
    }

    func testPositiveNegativeWrappingAndDebounce() async {
        let clock = FunctionClock()
        let s = session(target: .stepParameter(id: "x", step: 2, wraps: true),
                        definition: .init(id: "x", name: "X", minimum: 0, maximum: 10, defaultValue: 9), clock: clock)
        s.press(button)
        XCTAssertEqual(s.engine.value(of: "x"), 0)
        s.press(button)
        XCTAssertEqual(s.engine.value(of: "x"), 0)
        s.release(button)
        clock.now.addTimeInterval(1)
        XCTAssertNoThrow(try s.setAssignment(
            .init(control: button, target: .stepParameter(id: "x", step: -2, wraps: true)),
            for: button
        ))
        s.press(button)
        XCTAssertEqual(s.engine.value(of: "x"), 10)
        XCTAssertEqual(s.mock.value(of: button), 127)
    }

    func testConfigurationReplacementKeepsMockStepButtonResponsive() async throws {
        let s = session(target: .stepParameter(id: "x", step: 2, wraps: false),
                        definition: .init(id: "x", name: "X", minimum: 0, maximum: 10, defaultValue: 9))
        try s.replaceConfiguration(s.engine.configuration)
        XCTAssertEqual(s.mock.value(of: button), 127)
        s.press(button)
        XCTAssertEqual(s.engine.value(of: "x"), 10)
        XCTAssertEqual(s.mock.value(of: encoder), 127)
        XCTAssertEqual(s.mock.value(of: button), 0)
    }

    func testSetPresetLEDTracksSoftwareAndRelease() async {
        let s = session(target: .setParameter(id: "x", value: 30),
                        definition: .init(id: "x", name: "X", minimum: 0, maximum: 100))
        s.synchronize()
        XCTAssertEqual(s.mock.value(of: button), 0)
        s.press(button)
        XCTAssertEqual(s.engine.value(of: "x"), 30)
        XCTAssertEqual(s.mock.value(of: button), 127)
        s.release(button)
        XCTAssertEqual(s.mock.value(of: button), 127)
        s.setParameter("x", to: 40)
        XCTAssertEqual(s.mock.value(of: button), 0)
    }

    func testCycleOrderWrapAndUnlistedValue() async {
        let clock = FunctionClock()
        let s = session(target: .cycleParameter(id: "x", values: [-10, 0, 10]),
                        definition: .init(id: "x", name: "X", minimum: -10, maximum: 10, defaultValue: 0), clock: clock)
        for expected in [10.0, -10, 0] {
            s.press(button); s.release(button)
            XCTAssertEqual(s.engine.value(of: "x"), expected)
            XCTAssertEqual(s.mock.value(of: button), 127)
            clock.now.addTimeInterval(1)
        }
        s.setParameter("x", to: 2.5)
        XCTAssertEqual(s.mock.value(of: button), 0)
        s.press(button)
        XCTAssertEqual(s.engine.value(of: "x"), -10)
    }

    func testSnappedInputCorrectsItsOwnMockRingAndOtherBindings() async {
        let definition = ParameterDefinition(id: "x", name: "X", minimum: 0, maximum: 100, step: 10)
        let s = SurfaceSession(hardwareDevice: FunctionDevice(), configuration: SurfaceConfiguration(
            name: "Snap", parameters: [definition], assignments: [
                .init(control: encoder, target: .parameter("x")), .init(control: mirror, target: .parameter("x"))
            ]
        ), saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        s.synchronize()
        s.turn(encoder, by: 12)
        XCTAssertEqual(s.engine.value(of: "x"), 10)
        XCTAssertEqual(s.mock.value(of: encoder), 13)
        XCTAssertEqual(s.mock.value(of: mirror), 13)
        s.setParameter("x", to: 24)
        XCTAssertEqual(s.engine.value(of: "x"), 20)
        XCTAssertEqual(s.mock.value(of: encoder), s.mock.value(of: mirror))
    }

    func testStepQuantizationEndpointsTieAndCanonicalSevenBitRoundTrip() async throws {
        let p = ParameterDefinition(id: "x", name: "X", minimum: -10, maximum: 10, step: 0.5)
        XCTAssertEqual(p.clamp(0.25), 0)
        XCTAssertEqual(p.clamp(-0.25), -0.5)
        let irregular = ParameterDefinition(id: "x", name: "X", minimum: -0.3, maximum: 1.1, step: 0.5)
        XCTAssertEqual(irregular.clamp(-0.3), -0.3)
        XCTAssertEqual(irregular.clamp(1.09), 1.1)
        var seed: UInt64 = 0xBC2000
        for _ in 0 ..< 100 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let minimum = -Double(seed % 1000) / 13
            let span = Double((seed >> 12) % 1000 + 1) / 7
            let step = span / Double((seed >> 24) % 200 + 1)
            let definition = ParameterDefinition(
                id: "x",
                name: "X",
                minimum: minimum,
                maximum: minimum + span,
                step: step
            )
            try definition.validate()
            for midi in UInt8(0) ... 127 {
                let canonical = definition.midiValue(for: definition.value(fromMIDI: midi))
                XCTAssertEqual(definition.midiValue(for: definition.value(fromMIDI: canonical)), canonical)
            }
        }
    }

    func testEveryTriggerTypeRejectsEncodersAndInvalidFunctionValues() async {
        let definition = ParameterDefinition(id: "x", name: "X", minimum: 0, maximum: 10, step: 1)
        for target in [
            ControlTarget.stepParameter(id: "x", step: 1, wraps: false),
            .setParameter(id: "x", value: 3), .cycleParameter(id: "x", values: [0, 10])
        ] {
            var configuration = SurfaceConfiguration(name: "Test", parameters: [definition])
            XCTAssertThrowsError(try configuration.assign(.init(control: encoder, target: target)))
        }
        for target in [
            ControlTarget.stepParameter(id: "x", step: 0, wraps: false),
            .stepParameter(id: "x", step: .infinity, wraps: true),
            .setParameter(id: "x", value: 11), .setParameter(id: "x", value: .nan),
            .cycleParameter(id: "x", values: []), .cycleParameter(id: "x", values: [1, 1]),
            .cycleParameter(id: "x", values: [0.1, 0.2]), .cycleParameter(id: "x", values: [1, .nan])
        ] {
            XCTAssertThrowsError(try SurfaceConfiguration(name: "Test", parameters: [definition], assignments: [
                .init(control: button, target: target)
            ]).validate())
        }
        for step in [0.0, -1, .nan, .infinity, Double.leastNonzeroMagnitude] {
            XCTAssertThrowsError(try ParameterDefinition(id: "x", name: "X", step: step).validate())
        }
    }

    func testBulkPreviewPreservesValuesMappingAndAgentStateAndRejectsStalePlan() async throws {
        let s = SurfaceSession(
            hardwareDevice: FunctionDevice(),
            configuration: .robotArmDemo(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        s.setParameter("arm.j1", to: 37)
        s.setAgentFeedback(AgentSlotID(1), value: 96)
        let plan = try BulkAssignmentPlan(
            configuration: s.engine.configuration,
            section: .encoder,
            row: 1,
            group: SurfaceConfiguration.robotArmGroup
        )
        XCTAssertEqual(plan.changes.count, 8)
        XCTAssertEqual(plan.skippedParameters, 1)
        let map = s.engine.hardwareMap
        s.setParameter("arm.j1", to: 42)
        try s.applyBulkAssignment(plan)
        XCTAssertEqual(s.engine.value(of: "arm.j1"), 42)
        XCTAssertEqual(s.engine.hardwareMap, map)
        XCTAssertEqual(s.mock.value(of: .button(row: 1, 1)), 96)
        XCTAssertEqual(s.mock.value(of: encoder), s.mock.value(of: mirror))
        let stale = try BulkAssignmentPlan(
            configuration: s.engine.configuration,
            section: .encoder,
            row: 2,
            group: SurfaceConfiguration.robotArmGroup
        )
        var changed = s.engine.configuration.parameter("arm.j1")!
        changed.name = "Changed"
        try s.updateParameter(changed)
        let current = s.engine.configuration
        XCTAssertThrowsError(try s.applyBulkAssignment(stale)) { XCTAssertEqual(
            $0 as? ControlAssignmentPlanError,
            .stalePreview
        ) }
        XCTAssertEqual(s.engine.configuration, current)
        XCTAssertThrowsError(try BulkAssignmentPlan(
            configuration: current,
            section: .encoder,
            row: 9,
            group: "missing"
        ))
        XCTAssertThrowsError(try BulkAssignmentPlan(
            configuration: current,
            section: .encoder,
            row: 1,
            group: "missing"
        ))
    }

    func testOldConfigurationMigrationAndNewTargetsRoundTrip() async throws {
        var old = SurfaceConfiguration.robotArmDemo()
        old.version = 2
        let decoded = try JSONValue.encoded(old).decoded(SurfaceConfiguration.self).migrated()
        XCTAssertEqual(decoded.version, SurfaceConfiguration.currentVersion)
        XCTAssertNil(decoded.parameter("arm.j1")?.step)
        let definition = ParameterDefinition(id: "x", name: "X", minimum: 0, maximum: 10, step: 0.5)
        let targets: [ControlTarget] = [
            .stepParameter(id: "x", step: 0.5, wraps: true),
            .setParameter(id: "x", value: 3),
            .cycleParameter(id: "x", values: [0, 3, 10])
        ]
        for target in targets {
            let configuration = SurfaceConfiguration(
                name: "Test",
                parameters: [definition],
                assignments: [.init(control: button, target: target)]
            )
            XCTAssertEqual(try JSONValue.encoded(configuration).decoded(SurfaceConfiguration.self), configuration)
        }
    }
}
