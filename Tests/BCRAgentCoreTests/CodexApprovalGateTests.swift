import XCTest
@testable import BCRAgentCore
@testable import BCRMCPAdapter
@testable import BCRSurfaceDomain
@testable import BCRCodexAdapter

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

    func testDuplicateRequestCannotRenewAnExpiredApprovalWindow() async throws {
        let gate = CodexApprovalGate()
        let slot = AgentSlotID(1)
        let began = Date(timeIntervalSince1970: 1000)
        await gate.registerRequest("same", kind: .commandExecutionRequestApproval, for: slot,
                                   visibleSlotID: slot, requestedAt: began, visibleWindowSeconds: 1)
        await gate.clearExpiredRequests(now: began.addingTimeInterval(2))
        await gate.registerRequest("same", kind: .commandExecutionRequestApproval, for: slot,
                                   visibleSlotID: slot, requestedAt: began.addingTimeInterval(2))
        let pending = await gate.pendingRequestCount()
        XCTAssertEqual(pending, 0)
        do {
            _ = try await gate.resolveAgain(requestID: "same", by: slot, visibleSlotID: slot,
                                            at: began.addingTimeInterval(2), decision: .approve)
            XCTFail("Expired requests cannot be revived by replay")
        } catch CodexApprovalGateError.requestMissing {}
    }

    func testDefaultRequestRemainsActionableAfterReadingDetails() async throws {
        let gate = CodexApprovalGate()
        let now = Date(timeIntervalSince1970: 100)
        let slot = AgentSlotID(1)
        await gate.registerRequest(
            "read",
            kind: .commandExecutionRequestApproval,
            for: slot,
            visibleSlotID: slot,
            requestedAt: now
        )
        let sent = try await gate.resolveAgain(requestID: "read", by: slot, visibleSlotID: slot,
                                               at: now.addingTimeInterval(600), decision: .approve)
        XCTAssertTrue(sent)
    }

    func testExpiredRequestCanStillBeDeclinedAfterFailedApprove() async throws {
        let gate = CodexApprovalGate()
        let now = Date(timeIntervalSince1970: 100)
        let slot = AgentSlotID(1)
        await gate.registerRequest("expire", kind: .commandExecutionRequestApproval, for: slot,
                                   visibleSlotID: slot, requestedAt: now, visibleWindowSeconds: 1)
        do {
            _ = try await gate.resolveAgain(requestID: "expire", by: slot, visibleSlotID: slot,
                                            at: now.addingTimeInterval(2), decision: .approve)
            XCTFail("An explicitly expired approval cannot execute")
        } catch CodexApprovalGateError.requestExpired {}
        let sent = try await gate.resolveAgain(requestID: "expire", by: slot, visibleSlotID: slot,
                                               at: now.addingTimeInterval(3), decision: .decline)
        XCTAssertTrue(sent)
    }
}
