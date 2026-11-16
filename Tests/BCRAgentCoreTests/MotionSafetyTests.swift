import struct ParameterOutputPlugin.ParameterOutputPlugin
@testable import BCRFoundation
@testable import BCRCodexAdapter
@testable import BCRSurfaceDomain
@testable import BCRExamples
@testable import BCRConfigurationAdapter
@testable import BCRMCPAdapter
@testable import BCRHTTPTransport
@testable import BCRCoreMIDIDriver
@testable import BCRPersistenceAdapter
import struct ParameterOutputPlugin.MotionLimit
import enum ParameterOutputPlugin.MotionOutputPrecision
import Foundation
import XCTest

final class MotionSafetyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 8_000)
    private func gate(speed: Double = 10, change: Double = 2,
                      precision: MotionOutputPrecision = .double) throws -> ParameterOutputPlugin
    {
        try startedOutputFixture(limits: [.init(id: "x", minimum: -100, maximum: 100,
                                                maximumChange: change, maximumVelocity: speed)], precision: precision)
    }

    private func prepare(_ gate: inout ParameterOutputPlugin, at time: Date, actual: Double = 0) throws {
        gate.setConnected(true, at: time.timeIntervalSinceReferenceDate)
        gate.receiveHeartbeat(at: time.timeIntervalSinceReferenceDate)
        gate.receiveActual([.init(id: "x", value: actual, receivedAt: time.timeIntervalSinceReferenceDate)])
        _ = try evaluateFixture(&gate, targets: [:], enabled: false, at: time)
    }

    func testDisabledAndDisconnectedNeverProduceMotionFrames() throws {
        var g = try gate()
        XCTAssertNil(try evaluateFixture(&g, targets: ["x": 50], enabled: true, at: t0).command)
        try prepare(&g, at: t0)
        let decision = try evaluateFixture(&g, targets: ["x": 50], enabled: false, at: t0)
        XCTAssertEqual(decision.status, .disabled)
        XCTAssertEqual(decision.command, .init(enabled: false, values: [:]))
        XCTAssertTrue(g.gate.outputs.isEmpty)
    }

    func testPerCycleAndVelocityCapsAndInitialEnableDoNotJump() throws {
        var g = try gate(speed: 10, change: 0.5)
        try prepare(&g, at: t0)
        let initial = try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(initial.command, .init(enabled: true, values: ["x": 0]))
        XCTAssertEqual(g.gate.outputs["x"], 0)
        let next = try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: t0.addingTimeInterval(0.2))
        XCTAssertEqual(next.command?.values["x"], 0.5)
        XCTAssertTrue(next.limited)
        var velocity = try gate(speed: 2, change: 10)
        try prepare(&velocity, at: t0)
        _ = try evaluateFixture(&velocity, targets: ["x": -90], enabled: true, at: t0)
        _ = try evaluateFixture(&velocity, targets: ["x": -90], enabled: true, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(velocity.gate.outputs["x"]!, -0.2, accuracy: 1e-8)
    }

    func testSoftLimitsRemainEffectiveAndClockIsInjected() throws {
        var g = try gate(speed: 10_000, change: 10_000)
        try prepare(&g, at: t0, actual: 99)
        _ = try evaluateFixture(&g, targets: ["x": 999], enabled: true, at: t0)
        _ = try evaluateFixture(&g, targets: ["x": 999], enabled: true, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(g.gate.outputs["x"], 100)
        let same = try evaluateFixture(&g, targets: ["x": 999], enabled: true, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(same.command?.values, ["x": 100])
        XCTAssertTrue(same.limited)
    }

    func testDisableTimeoutAndDisconnectNeverRepeatMovement() throws {
        for reason in 0 ..< 3 {
            var g = try gate()
            try prepare(&g, at: t0)
            _ = try evaluateFixture(&g, targets: ["x": 50], enabled: true, at: t0)
            let time: Date
            let enabled: Bool
            if reason == 0 { time = t0.addingTimeInterval(0.1); enabled = false }
            else if reason == 1 { time = t0.addingTimeInterval(0.3); enabled = true }
            else { time = t0.addingTimeInterval(0.1); enabled = true; g.setConnected(
                false,
                at: time.timeIntervalSinceReferenceDate
            ) }
            let result = try evaluateFixture(&g, targets: ["x": 50], enabled: enabled, at: time)
            XCTAssertEqual(result.command, .init(enabled: false, values: [:]))
            XCTAssertNotEqual(result.status, .ready)
            let repeated = try evaluateFixture(&g, targets: ["x": 80], enabled: enabled, at: time).command
            XCTAssertTrue(repeated == nil || repeated == .init(enabled: false, values: [:]))
        }
    }

    func testMissingHeartbeatAndActualStateFailClosedAtBoundary() throws {
        var g = try gate()
        g.setConnected(true, at: t0.timeIntervalSinceReferenceDate)
        XCTAssertEqual(try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0).status, .waitingHeartbeat)
        XCTAssertEqual(
            try evaluateFixture(&g, targets: ["x": 1], enabled: false, at: t0.addingTimeInterval(0.3)).status,
            .heartbeatExpired
        )
        g.receiveHeartbeat(at: t0.addingTimeInterval(0.3).timeIntervalSinceReferenceDate)
        XCTAssertEqual(
            try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0.addingTimeInterval(0.3)).status,
            .waitingActual
        )
        g.receiveActual([.init(id: "x", value: 0, receivedAt: t0.timeIntervalSinceReferenceDate)])
        XCTAssertEqual(
            try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0.addingTimeInterval(0.3)).status,
            .waitingActual
        )
    }

    func testInvalidTargetActualAndClockNeverReachSink() throws {
        var g = try gate()
        try prepare(&g, at: t0)
        XCTAssertEqual(try evaluateFixture(&g, targets: ["x": .nan], enabled: true, at: t0).status, .invalidTarget)
        XCTAssertEqual(try evaluateFixture(&g, targets: [:], enabled: true, at: t0).status, .invalidTarget)
        g.receiveActual([.init(id: "x", value: 101, receivedAt: t0.timeIntervalSinceReferenceDate)])
        XCTAssertEqual(try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0).status, .actualOutOfLimits)
        g.receiveActual([.init(id: "x", value: .nan, receivedAt: t0.timeIntervalSinceReferenceDate)])
        XCTAssertEqual(try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0).status, .invalidActual)
        g.setConnected(false, at: t0.timeIntervalSinceReferenceDate)
        try prepare(&g, at: t0)
        _ = try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0)
        XCTAssertEqual(
            try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0.addingTimeInterval(-1)).status,
            .clockError
        )
        XCTAssertEqual(try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0).status, .clockError)
    }

    func testReconnectAndReenableSeedFromFreshActualRatherThanOldCommands() throws {
        var g = try gate()
        try prepare(&g, at: t0)
        _ = try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: t0)
        _ = try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: t0.addingTimeInterval(0.1))
        _ = try evaluateFixture(&g, targets: ["x": 90], enabled: false, at: t0.addingTimeInterval(0.2))
        let time = t0.addingTimeInterval(0.25)
        g.receiveHeartbeat(at: time.timeIntervalSinceReferenceDate)
        g.receiveActual([.init(id: "x", value: 20, receivedAt: time.timeIntervalSinceReferenceDate)])
        let enable = try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: time)
        XCTAssertEqual(g.gate.outputs["x"], 20)
        XCTAssertEqual(g.gate.baseline["x"], 20)
        XCTAssertEqual(enable.command?.values, ["x": 20])
        g.setConnected(false, at: time.timeIntervalSinceReferenceDate)
        _ = try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: time)
        try prepare(&g, at: time, actual: -20)
        _ = try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: time)
        XCTAssertEqual(g.gate.outputs["x"], -20)
        XCTAssertEqual(g.gate.baseline["x"], -20)
    }

    func testFloatWireQuantizationStaysInsideSoftAndVelocityLimits() throws {
        var g = try startedOutputFixture(
            limits: [.init(id: "x", minimum: 0, maximum: 0.1, maximumChange: 1, maximumVelocity: 1)],
            precision: .float32
        )
        try prepare(&g, at: t0)
        _ = try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0)
        _ = try evaluateFixture(&g, targets: ["x": 1], enabled: true, at: t0.addingTimeInterval(0.2))
        let output = try XCTUnwrap(g.gate.outputs["x"])
        XCTAssertLessThanOrEqual(output, 0.1)
        XCTAssertEqual(Double(Float(output)), output)
        var slow = try gate(speed: 0.1, change: 1, precision: .float32)
        try prepare(&slow, at: t0)
        _ = try evaluateFixture(&slow, targets: ["x": 50], enabled: true, at: t0)
        _ = try evaluateFixture(&slow, targets: ["x": 50], enabled: true, at: t0.addingTimeInterval(0.02))
        XCTAssertLessThanOrEqual(slow.gate.outputs["x"]!, 0.1 * 0.02 + 1e-12)
    }

    func testLimitValidationRejectsUnsafeSettings() {
        for limit in [
            MotionLimit(id: "x", minimum: 0, maximum: 0, maximumChange: 1, maximumVelocity: 1),
            .init(id: "x", minimum: 0, maximum: 1, maximumChange: 0, maximumVelocity: 1),
            .init(id: "x", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: .infinity)
        ] { XCTAssertThrowsError(try startedOutputFixture(limits: [limit])) }
        XCTAssertThrowsError(try startedOutputFixture(limits: []))
        XCTAssertThrowsError(try startedOutputFixture(
            limits: [.init(id: "x", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: 1)],
            heartbeatTimeout: 1
        ))
    }

    func testAlreadyEnabledStartupAndReconnectRequireObservedOffThenOn() throws {
        var g = try gate()
        g.setConnected(true, at: t0.timeIntervalSinceReferenceDate)
        g.receiveHeartbeat(at: t0.timeIntervalSinceReferenceDate)
        g.receiveActual([.init(id: "x", value: 0, receivedAt: t0.timeIntervalSinceReferenceDate)])
        for _ in 0 ..< 3 {
            let held = try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: t0)
            XCTAssertEqual(held.status, .waitingRearm)
            XCTAssertEqual(held.command, .init(enabled: false, values: [:]))
            XCTAssertTrue(g.gate.outputs.isEmpty)
        }
        _ = try evaluateFixture(&g, targets: ["x": 90], enabled: false, at: t0)
        XCTAssertEqual(try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: t0).status, .ready)
        let expired = t0.addingTimeInterval(0.3)
        XCTAssertEqual(
            try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: expired).status,
            .heartbeatExpired
        )
        g.receiveHeartbeat(at: expired.timeIntervalSinceReferenceDate)
        g.receiveActual([.init(id: "x", value: 1, receivedAt: expired.timeIntervalSinceReferenceDate)])
        XCTAssertEqual(try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: expired).status, .waitingRearm)
        _ = try evaluateFixture(&g, targets: ["x": 90], enabled: false, at: expired)
        XCTAssertEqual(try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: expired).status, .ready)
        g.setConnected(false, at: expired.timeIntervalSinceReferenceDate)
        g.setConnected(true, at: expired.timeIntervalSinceReferenceDate)
        g.receiveHeartbeat(at: expired.timeIntervalSinceReferenceDate)
        g.receiveActual([.init(id: "x", value: 2, receivedAt: expired.timeIntervalSinceReferenceDate)])
        XCTAssertEqual(try evaluateFixture(&g, targets: ["x": 90], enabled: true, at: expired).status, .waitingRearm)
    }

    func testEveryReadyFrameContainsAllLimitedOutputsIncludingUnchangedJoints() throws {
        var g = try startedOutputFixture(limits: [
            .init(id: "x", minimum: -100, maximum: 100, maximumChange: 1, maximumVelocity: 10),
            .init(id: "y", minimum: -100, maximum: 100, maximumChange: 1, maximumVelocity: 10)
        ])
        g.setConnected(true, at: t0.timeIntervalSinceReferenceDate)
        g.receiveHeartbeat(at: t0.timeIntervalSinceReferenceDate)
        g.receiveActual([
            .init(id: "x", value: 0, receivedAt: t0.timeIntervalSinceReferenceDate),
            .init(id: "y", value: 5, receivedAt: t0.timeIntervalSinceReferenceDate)
        ])
        _ = try evaluateFixture(&g, targets: [:], enabled: false, at: t0)
        for i in 0 ..< 3 {
            let decision = try evaluateFixture(&g,
                                               targets: ["x": 1, "y": 5],
                                               enabled: true,
                                               at: t0.addingTimeInterval(Double(i) * 0.1))
            XCTAssertEqual(Set(decision.command!.values.keys), Set(["x", "y"]))
            XCTAssertEqual(decision.command!.values["y"], 5)
        }
        let retry = try evaluateFixture(&g, targets: ["x": 1, "y": 5], enabled: true, at: t0.addingTimeInterval(0.2))
        XCTAssertEqual(retry.command?.values, ["x": 1, "y": 5])
        for _ in 0 ..< 3 {
            XCTAssertEqual(
                try evaluateFixture(&g, targets: [:], enabled: false, at: t0.addingTimeInterval(0.2)).command,
                .init(enabled: false, values: [:])
            )
        }
    }
}
