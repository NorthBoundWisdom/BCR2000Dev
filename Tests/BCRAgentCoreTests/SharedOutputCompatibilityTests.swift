import BCRAgentCore
import Foundation
import XCTest

// Public defaults prove that the compatibility facade re-exports only the needed
// shared symbols; callers do not have to import a new implementation module.
public func legacyOutputDefaults(json: JSONValue = .object([:]), state: AgentRunState = .idle,
                                 precision: MotionOutputPrecision = .double) -> JSONValue { json }

final class SharedOutputCompatibilityTests: XCTestCase {
    private let id = ParameterID("joint")
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    private func gate() throws -> MotionSafetyGate {
        var gate = try MotionSafetyGate(limits: [
            .init(id: id, minimum: 0, maximum: 10, maximumChange: 1, maximumVelocity: 2)
        ])
        gate.setConnected(true, at: start)
        gate.receiveHeartbeat(at: start)
        _ = gate.evaluate(targets: [id: 5], enabled: false, at: start)
        return gate
    }

    func testSharedFailureParameterIDRestoresAllThreeLegacyDiagnosticMessages() throws {
        var gate = try gate()
        var decision = gate.evaluate(targets: [id: 5], enabled: true, at: start)
        XCTAssertEqual(decision.status, .waitingActual)
        XCTAssertEqual(decision.parameterID, id)
        XCTAssertEqual(decision.reason, L10n.text("等待新鲜实际状态：\(id)"))
        XCTAssertEqual(gate.plugin.decision?.parameterID, id)
        gate.receiveActual([.init(id: id, value: -1, receivedAt: start)])
        decision = gate.evaluate(targets: [id: 5], enabled: true, at: start)
        XCTAssertEqual(decision.status, .actualOutOfLimits)
        XCTAssertEqual(decision.reason, L10n.text("实际状态超出软限位：\(id)"))
        gate.receiveActual([.init(id: id, value: 1, receivedAt: start)])
        decision = gate.evaluate(targets: [:], enabled: true, at: start)
        XCTAssertEqual(decision.status, .invalidTarget)
        XCTAssertEqual(decision.reason, L10n.text("目标缺失或不是有限数值：\(id)"))
    }

    func testHeartbeatGapRequiresExplicitOffOnEvenWhenFreshHeartbeatArrivesBeforeEvaluation() throws {
        var gate = try gate()
        gate.receiveActual([.init(id: id, value: 1, receivedAt: start)])
        XCTAssertEqual(gate.evaluate(targets: [id: 5], enabled: true, at: start).status, .ready)
        let late = start.addingTimeInterval(1)
        gate.receiveHeartbeat(at: late)
        gate.receiveActual([.init(id: id, value: 1, receivedAt: late)])
        let stopped = gate.evaluate(targets: [id: 5], enabled: true, at: late)
        XCTAssertEqual(stopped.status, .waitingRearm)
        XCTAssertEqual(stopped.command?.enabled, false)
        XCTAssertEqual(gate.evaluate(targets: [id: 5], enabled: false, at: late).status, .disabled)
        XCTAssertEqual(gate.evaluate(targets: [id: 5], enabled: true, at: late).status, .ready)
    }

    func testRegressingHeartbeatLatchesVisibleClockFailure() throws {
        var gate = try gate()
        gate.receiveHeartbeat(at: start.addingTimeInterval(-0.1))
        let decision = gate.evaluate(targets: [id: 5], enabled: false, at: start)
        XCTAssertEqual(decision.status, .clockError)
        XCTAssertEqual(decision.reason, L10n.text("心跳时间倒退，需重新连接安全门"))
        XCTAssertEqual(legacyOutputDefaults(), .object([:]))
    }

    func testSharedExamplePreservesAllLegacyMetadataAndExplicitProtection() {
        let example = SurfaceConfiguration.robotArmDemo()
        let expected: [(String, Double, Double, Double, LocalizedMessage)] = [
            ("arm.j1", -180, 180, 0, "J1 底座旋转"), ("arm.j2", -90, 90, 30, "J2 肩部"),
            ("arm.j3", -135, 135, -60, "J3 肘部"), ("arm.j4", -120, 120, -20, "J4 腕部俯仰"),
            ("arm.j5", -180, 180, 0, "J5 腕部旋转"), ("arm.j6", -180, 180, 0, "J6 末端旋转"),
            ("arm.gripper", 0, 100, 40, "夹爪开合"), ("arm.speed", 0, 100, 50, "运动速度"),
            ("arm.enabled", 0, 1, 0, "使能")
        ]
        XCTAssertEqual(example.parameters.count, expected.count)
        for (definition, legacy) in zip(example.parameters, expected) {
            XCTAssertEqual(definition.id.rawValue, legacy.0)
            XCTAssertEqual(definition.minimum, legacy.1)
            XCTAssertEqual(definition.maximum, legacy.2)
            XCTAssertEqual(definition.defaultValue, legacy.3)
            XCTAssertEqual(definition.name, L10n.text(legacy.4))
            XCTAssertEqual(definition.group, SurfaceConfiguration.robotArmGroup)
            XCTAssertEqual(definition.externallyProtected, definition.id == "arm.enabled")
            XCTAssertEqual(definition.agentWritable, definition.id != "arm.enabled")
        }
        XCTAssertEqual(LegacyExampleProtection.parameterIDs, ["arm.enabled"])
    }
}
