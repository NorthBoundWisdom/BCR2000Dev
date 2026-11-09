import Foundation
import XCTest
@testable import BCRAgentCore

final class MotionSafetyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 8_000)
    private func gate(speed: Double = 10, change: Double = 2, precision: MotionOutputPrecision = .double) throws -> MotionSafetyGate {
        try MotionSafetyGate(limits: [.init(id: "x", minimum: -100, maximum: 100,
                                           maximumChange: change, maximumVelocity: speed)], precision: precision)
    }
    private func prepare(_ gate: inout MotionSafetyGate, at time: Date, actual: Double = 0) {
        gate.setConnected(true, at: time)
        gate.receiveHeartbeat(at: time)
        gate.receiveActual([.init(id: "x", value: actual, receivedAt: time)])
    }

    func testDisabledAndDisconnectedNeverProduceMotionFrames() throws {
        var g = try gate()
        XCTAssertNil(g.evaluate(targets: ["x": 50], enabled: true, at: t0).command)
        prepare(&g, at: t0)
        let decision = g.evaluate(targets: ["x": 50], enabled: false, at: t0)
        XCTAssertEqual(decision.status, .disabled)
        XCTAssertNil(decision.command)
        XCTAssertTrue(g.outputs.isEmpty)
    }

    func testPerCycleAndVelocityCapsAndInitialEnableDoNotJump() throws {
        var g = try gate(speed: 10, change: 0.5)
        prepare(&g, at: t0)
        let initial = g.evaluate(targets: ["x": 90], enabled: true, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(initial.command, .init(enabled: true, values: [:]))
        XCTAssertEqual(g.outputs["x"], 0)
        let next = g.evaluate(targets: ["x": 90], enabled: true, at: t0.addingTimeInterval(0.2))
        XCTAssertEqual(next.command?.values["x"], 0.5)
        XCTAssertTrue(next.limited)
        var velocity = try gate(speed: 2, change: 10)
        prepare(&velocity, at: t0)
        _ = velocity.evaluate(targets: ["x": -90], enabled: true, at: t0)
        _ = velocity.evaluate(targets: ["x": -90], enabled: true, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(velocity.outputs["x"]!, -0.2, accuracy: 1e-8)
    }

    func testSoftLimitsRemainEffectiveAndClockIsInjected() throws {
        var g = try gate(speed: 10_000, change: 10_000)
        prepare(&g, at: t0, actual: 99)
        _ = g.evaluate(targets: ["x": 999], enabled: true, at: t0)
        _ = g.evaluate(targets: ["x": 999], enabled: true, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(g.outputs["x"], 100)
        let same = g.evaluate(targets: ["x": 999], enabled: true, at: t0.addingTimeInterval(0.1))
        XCTAssertNil(same.command)
        XCTAssertTrue(same.limited)
    }

    func testDisableTimeoutAndDisconnectEmitStopThenNoMoreCommands() throws {
        for reason in 0..<3 {
            var g = try gate()
            prepare(&g, at: t0)
            _ = g.evaluate(targets: ["x": 50], enabled: true, at: t0)
            let time: Date
            let enabled: Bool
            if reason == 0 { time = t0.addingTimeInterval(0.1); enabled = false }
            else if reason == 1 { time = t0.addingTimeInterval(0.3); enabled = true }
            else { time = t0.addingTimeInterval(0.1); enabled = true; g.setConnected(false, at: time) }
            let result = g.evaluate(targets: ["x": 50], enabled: enabled, at: time)
            XCTAssertEqual(result.command, .init(enabled: false, values: [:]))
            XCTAssertNotEqual(result.status, .ready)
            XCTAssertNil(g.evaluate(targets: ["x": 80], enabled: enabled, at: time).command)
        }
    }

    func testMissingHeartbeatAndActualStateFailClosedAtBoundary() throws {
        var g = try gate()
        g.setConnected(true, at: t0)
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0).status, .waitingHeartbeat)
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: false, at: t0.addingTimeInterval(0.3)).status, .heartbeatExpired)
        g.receiveHeartbeat(at: t0.addingTimeInterval(0.3))
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0.addingTimeInterval(0.3)).status, .waitingActual)
        g.receiveActual([.init(id: "x", value: 0, receivedAt: t0)])
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0.addingTimeInterval(0.3)).status, .waitingActual)
    }

    func testInvalidTargetActualAndClockNeverReachSink() throws {
        var g = try gate()
        prepare(&g, at: t0)
        XCTAssertEqual(g.evaluate(targets: ["x": .nan], enabled: true, at: t0).status, .invalidTarget)
        XCTAssertEqual(g.evaluate(targets: [:], enabled: true, at: t0).status, .invalidTarget)
        g.receiveActual([.init(id: "x", value: 101, receivedAt: t0)])
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0).status, .actualOutOfLimits)
        g.receiveActual([.init(id: "x", value: .nan, receivedAt: t0)])
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0).status, .invalidActual)
        g.setConnected(false, at: t0)
        prepare(&g, at: t0)
        _ = g.evaluate(targets: ["x": 1], enabled: true, at: t0)
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0.addingTimeInterval(-1)).status, .clockError)
        XCTAssertEqual(g.evaluate(targets: ["x": 1], enabled: true, at: t0).status, .clockError)
    }

    func testReconnectAndReenableSeedFromFreshActualRatherThanOldCommands() throws {
        var g = try gate()
        prepare(&g, at: t0)
        _ = g.evaluate(targets: ["x": 90], enabled: true, at: t0)
        _ = g.evaluate(targets: ["x": 90], enabled: true, at: t0.addingTimeInterval(0.1))
        _ = g.evaluate(targets: ["x": 90], enabled: false, at: t0.addingTimeInterval(0.2))
        let time = t0.addingTimeInterval(0.25)
        g.receiveHeartbeat(at: time)
        g.receiveActual([.init(id: "x", value: 20, receivedAt: time)])
        let enable = g.evaluate(targets: ["x": 90], enabled: true, at: time)
        XCTAssertEqual(g.outputs["x"], 20)
        XCTAssertEqual(g.baseline["x"], 20)
        XCTAssertEqual(enable.command?.values, [:])
        g.setConnected(false, at: time)
        _ = g.evaluate(targets: ["x": 90], enabled: true, at: time)
        prepare(&g, at: time, actual: -20)
        _ = g.evaluate(targets: ["x": 90], enabled: true, at: time)
        XCTAssertEqual(g.outputs["x"], -20)
        XCTAssertEqual(g.baseline["x"], -20)
    }

    func testFloatWireQuantizationStaysInsideSoftAndVelocityLimits() throws {
        var g = try MotionSafetyGate(limits: [.init(id: "x", minimum: 0, maximum: 0.1, maximumChange: 1, maximumVelocity: 1)], precision: .float32)
        prepare(&g, at: t0)
        _ = g.evaluate(targets: ["x": 1], enabled: true, at: t0)
        _ = g.evaluate(targets: ["x": 1], enabled: true, at: t0.addingTimeInterval(0.2))
        let output = try XCTUnwrap(g.outputs["x"])
        XCTAssertLessThanOrEqual(output, 0.1)
        XCTAssertEqual(Double(Float(output)), output)
        var slow = try gate(speed: 0.1, change: 1, precision: .float32)
        prepare(&slow, at: t0)
        _ = slow.evaluate(targets: ["x": 50], enabled: true, at: t0)
        _ = slow.evaluate(targets: ["x": 50], enabled: true, at: t0.addingTimeInterval(0.02))
        XCTAssertLessThanOrEqual(slow.outputs["x"]!, 0.1 * 0.02 + 1e-12)
    }

    func testLimitValidationRejectsUnsafeSettings() {
        for limit in [
            MotionLimit(id: "x", minimum: 0, maximum: 0, maximumChange: 1, maximumVelocity: 1),
            .init(id: "x", minimum: 0, maximum: 1, maximumChange: 0, maximumVelocity: 1),
            .init(id: "x", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: .infinity),
        ] { XCTAssertThrowsError(try MotionSafetyGate(limits: [limit])) }
        XCTAssertThrowsError(try MotionSafetyGate(limits: []))
        XCTAssertThrowsError(try MotionSafetyGate(limits: [.init(id: "x", minimum: 0, maximum: 1, maximumChange: 1, maximumVelocity: 1)], heartbeatTimeout: 1))
    }
}
