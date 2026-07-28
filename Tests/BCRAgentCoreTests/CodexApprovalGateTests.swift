import XCTest
@testable import BCRAgentCore

final class CodexApprovalGateTests: XCTestCase {
    func testDuplicateDecisionIsIdempotent() async throws {
        let gate = CodexApprovalGate()
        let slotID = AgentSlotID(1)

        await gate.registerRequest(
            "req-1",
            kind: .commandExecutionRequestApproval,
            for: slotID,
            visibleSlotID: slotID
        )

        let first = try await gate.resolveAgain(
            requestID: "req-1",
            by: slotID,
            visibleSlotID: slotID,
            decision: .approve
        )
        XCTAssertTrue(first)

        let second = try await gate.resolveAgain(
            requestID: "req-1",
            by: slotID,
            visibleSlotID: slotID,
            decision: .approve
        )
        XCTAssertFalse(second)
    }

    func testExpiredRequestCannotBeApproved() async {
        let gate = CodexApprovalGate()
        let slotID = AgentSlotID(2)
        let now = Date()
        await gate.registerRequest(
            "req-exp",
            kind: .fileChangeRequestApproval,
            for: slotID,
            visibleSlotID: slotID,
            requestedAt: now,
            visibleWindowSeconds: 1
        )

        try? await Task.sleep(for: .seconds(2))

        do {
            _ = try await gate.resolveAgain(
                requestID: "req-exp",
                by: slotID,
                visibleSlotID: slotID,
                at: .now,
                decision: .approve
            )
            XCTFail("过期请求不应被通过")
        } catch {
            XCTAssertTrue(error is CodexApprovalGateError)
        }
    }

    func testVisibilityMismatchRejected() async {
        let gate = CodexApprovalGate()
        let slotID = AgentSlotID(3)
        await gate.registerRequest(
            "req-vis",
            kind: .commandExecutionRequestApproval,
            for: slotID,
            visibleSlotID: slotID
        )

        do {
            _ = try await gate.resolveAgain(
                requestID: "req-vis",
                by: slotID,
                visibleSlotID: AgentSlotID(4),
                decision: .decline
            )
            XCTFail("可见性不一致应拒绝")
        } catch {
            XCTAssertTrue(error is CodexApprovalGateError)
        }
    }

    func testConflictingDecisionIsRejected() async {
        let gate = CodexApprovalGate()
        let slotID = AgentSlotID(4)
        await gate.registerRequest(
            "req-conflict",
            kind: .commandExecutionRequestApproval,
            for: slotID,
            visibleSlotID: slotID
        )

        _ = try? await gate.resolveAgain(
            requestID: "req-conflict",
            by: slotID,
            visibleSlotID: slotID,
            decision: .approve
        )

        do {
            _ = try await gate.resolveAgain(
                requestID: "req-conflict",
                by: slotID,
                visibleSlotID: slotID,
                decision: .decline
            )
            XCTFail("冲突决策应抛出")
        } catch {
            XCTAssertTrue(error is CodexApprovalGateError)
        }
    }
}
