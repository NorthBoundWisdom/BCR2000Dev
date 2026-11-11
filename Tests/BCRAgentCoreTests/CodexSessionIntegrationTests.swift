import Foundation
import XCTest
@testable import BCRAgentCore

@MainActor
final class CodexSessionIntegrationTests: XCTestCase {
    private func makeSession(approvalWindow: TimeInterval? = nil,
                             failApprovalResponses: Int = 0) async throws -> CodexSessionCoordinator
    {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/mock_app_server.py")
        let process = CodexProcessSupervisor()
        try await process.start(executablePath: "/usr/bin/python3", arguments: ["-u", fixture.path])
        let cache = FileManager.default.temporaryDirectory.appending(path: "bcr-catalog-\(UUID().uuidString).json")
        return CodexSessionCoordinator(
            transport: ApprovalFaultTransport(base: process, failures: failApprovalResponses),
            modelCatalogStore: CodexModelCatalogStore(fileURL: cache),
            approvalWindow: approvalWindow
        )
    }

    private func wait(_ session: CodexSessionCoordinator, slot: AgentSlotID, phase: CodexTurnPhase) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await session.snapshot().states[slot]?.phase == phase { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let failed = await session.snapshot()
        XCTFail(
            "Expected \(phase); got \(String(describing: failed.states[slot])), connection \(failed.phase), error \(failed.error ?? "none")"
        )
        throw CancellationError()
    }

    func testHandshakeThreadTurnApprovalInterruptStopAndFreshReconnect() async throws {
        let session = try await makeSession()
        try await session.start()
        let connected = await session.snapshot()
        XCTAssertEqual(connected.phase, .ready)
        XCTAssertEqual(connected.models.first?.supportedReasoningEfforts, ["low"])
        let slot = AgentSlotID(1)
        try await session.startTurn(
            slotID: slot,
            userPrompt: "approval",
            modelID: "fixture",
            permission: .init(type: .safeRead)
        )
        try await wait(session, slot: slot, phase: .awaitingApproval)
        let pending = await session.snapshot().approvals
        let request = try XCTUnwrap(pending.first)
        guard case .number = request.id else { return XCTFail("Numeric request IDs must be preserved") }
        let approvalState = await session.snapshot().states[slot]
        let duplicate = CodexEnvelope(id: request.id, method: CodexMethod.commandExecutionRequestApproval.rawValue,
                                      params: .object(["threadId": .string(try XCTUnwrap(approvalState?.threadID)),
                                                       "turnId": .string(try XCTUnwrap(approvalState?.turnID))]))
        await session.onServerEnvelope(duplicate)
        let stillPending = await session.snapshot()
        XCTAssertEqual(stillPending.approvals.count, 1)
        try await session.sendApproval(
            requestID: request.id.stringValue,
            slotID: slot,
            visibleSlotID: slot,
            decision: .approve
        )
        try await wait(session, slot: slot, phase: .completed)
        await session.onServerEnvelope(duplicate)
        let afterReplay = await session.snapshot()
        XCTAssertTrue(afterReplay.approvals.isEmpty)
        XCTAssertEqual(afterReplay.states[slot]?.phase, .completed)
        try await session.startTurn(
            slotID: slot,
            userPrompt: "hold",
            modelID: "fixture",
            permission: .init(type: .safeRead)
        )
        try await wait(session, slot: slot, phase: .running)
        try await session.interruptTurn(slotID: slot)
        let interrupted = await session.snapshot()
        XCTAssertEqual(interrupted.states[slot]?.phase, .interrupted)
        await session.stop()
        let stopped = await session.snapshot()
        XCTAssertTrue(stopped.states.values.allSatisfy { $0.phase == .idle && $0.threadID == nil })
        let reconnected = try await makeSession()
        try await reconnected.start()
        try await reconnected.startTurn(
            slotID: slot,
            userPrompt: "complete",
            modelID: "fixture",
            permission: .init(type: .safeRead)
        )
        try await wait(reconnected, slot: slot, phase: .completed)
        await reconnected.stop()
    }

    func testTwoApprovalsForOneTurnBothReceiveReplies() async throws {
        let session = try await makeSession()
        try await session.start()
        let slot = AgentSlotID(1)
        try await session.startTurn(
            slotID: slot,
            userPrompt: "parallel_approval",
            modelID: "fixture",
            permission: .init(type: .safeRead)
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await session.snapshot().approvals.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await session.snapshot().approvals
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            try await session.sendApproval(
                requestID: request.id.stringValue,
                slotID: slot,
                visibleSlotID: slot,
                decision: .approve
            )
            if index == 0 {
                let state = await session.snapshot()
                XCTAssertEqual(state.states[slot]?.phase, .awaitingApproval)
                XCTAssertEqual(state.approvals.count, 1)
            }
        }
        try await wait(session, slot: slot, phase: .completed)
        await session.stop()
    }

    func testExpiredApprovalIsDeclinedAndSlotCanStartAgain() async throws {
        for decision in [CodexApprovalDecision.approve, .decline] {
            let session = try await makeSession(approvalWindow: 0)
            try await session.start()
            let slot = AgentSlotID(1)
            try await session.startTurn(
                slotID: slot,
                userPrompt: "approval",
                modelID: "fixture",
                permission: .init(type: .safeRead)
            )
            try await wait(session, slot: slot, phase: .awaitingApproval)
            let pending = await session.snapshot().approvals
            let request = try XCTUnwrap(pending.first)
            try await session.sendApproval(id: request.id, slotID: slot, visibleSlotID: slot, decision: decision)
            try await wait(session, slot: slot, phase: .interrupted)
            let resolved = await session.snapshot()
            XCTAssertTrue(resolved.approvals.isEmpty)
            XCTAssertEqual(resolved.phase, .ready)
            try await session.startTurn(
                slotID: slot,
                userPrompt: "complete",
                modelID: "fixture",
                permission: .init(type: .safeRead)
            )
            try await wait(session, slot: slot, phase: .completed)
            await session.stop()
        }
    }

    func testFailedApprovalSendIsRetryableWithConcurrentRequestStillWaiting() async throws {
        let session = try await makeSession(failApprovalResponses: 1)
        try await session.start()
        let slot = AgentSlotID(1)
        try await session.startTurn(
            slotID: slot,
            userPrompt: "parallel_approval",
            modelID: "fixture",
            permission: .init(type: .safeRead)
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await session.snapshot().approvals.count < 2,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let requests = await session.snapshot().approvals
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first)
        do {
            try await session.sendApproval(id: first.id, slotID: slot, visibleSlotID: slot, decision: .approve)
            XCTFail("The injected transport failure must be visible")
        } catch ApprovalFaultTransport.Failure.unavailable {}
        let failed = await session.snapshot()
        XCTAssertEqual(failed.approvals.count, 2)
        XCTAssertEqual(failed.states[slot]?.phase, .awaitingApproval)
        XCTAssertNotNil(failed.error)
        for request in requests {
            try await session.sendApproval(id: request.id, slotID: slot, visibleSlotID: slot, decision: .approve)
        }
        try await wait(session, slot: slot, phase: .completed)
        let completed = await session.snapshot()
        XCTAssertTrue(completed.approvals.isEmpty)
        XCTAssertNil(completed.error)
        await session.stop()
    }

    func testNumericAndStringApprovalIDsDoNotCollide() async throws {
        let session = try await makeSession()
        try await session.start()
        let slot = AgentSlotID(1)
        try await session.startTurn(
            slotID: slot,
            userPrompt: "mixed_id_approval",
            modelID: "fixture",
            permission: .init(type: .safeRead)
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await session.snapshot().approvals.count < 2,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let requests = await session.snapshot().approvals
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests.map(\.id)).count, 2)
        let first = try XCTUnwrap(requests.first)
        do {
            try await session.sendApproval(
                requestID: first.id.stringValue,
                slotID: slot,
                visibleSlotID: slot,
                decision: .approve
            )
            XCTFail("An ambiguous text ID must never select a request")
        } catch CodexApprovalGateError.requestMissing {}
        for request in requests { try await session.sendApproval(
            id: request.id,
            slotID: slot,
            visibleSlotID: slot,
            decision: .approve
        ) }
        try await wait(session, slot: slot, phase: .completed)
        await session.stop()
    }

    func testCancelledApprovalIntentDoesNotConsumeOrSendRequest() async throws {
        let session = try await makeSession()
        try await session.start()
        let slot = AgentSlotID(1)
        try await session.startTurn(
            slotID: slot,
            userPrompt: "approval",
            modelID: "fixture",
            permission: .init(type: .safeRead)
        )
        try await wait(session, slot: slot, phase: .awaitingApproval)
        let pending = await session.snapshot().approvals
        let request = try XCTUnwrap(pending.first)
        let response = Task { try await session.sendApproval(
            id: request.id,
            slotID: slot,
            visibleSlotID: slot,
            decision: .approve
        ) }
        response.cancel()
        do { try await response.value; XCTFail("Cancelled intent must not send") } catch is CancellationError {}
        let unchanged = await session.snapshot()
        XCTAssertEqual(unchanged.approvals.count, 1)
        XCTAssertEqual(unchanged.states[slot]?.phase, .awaitingApproval)
        try await session.sendApproval(id: request.id, slotID: slot, visibleSlotID: slot, decision: .decline)
        try await wait(session, slot: slot, phase: .interrupted)
        await session.stop()
    }

    func testFailedApproveCanBeChangedToDecline() async throws {
        let session = try await makeSession(failApprovalResponses: 1)
        try await session.start()
        let slot = AgentSlotID(1)
        try await session.startTurn(
            slotID: slot,
            userPrompt: "approval",
            modelID: "fixture",
            permission: .init(type: .safeRead)
        )
        try await wait(session, slot: slot, phase: .awaitingApproval)
        let pending = await session.snapshot().approvals
        let request = try XCTUnwrap(pending.first)
        do {
            try await session.sendApproval(id: request.id, slotID: slot, visibleSlotID: slot, decision: .approve)
            XCTFail("Expected transport failure")
        } catch ApprovalFaultTransport.Failure.unavailable {}
        try await session.sendApproval(id: request.id, slotID: slot, visibleSlotID: slot, decision: .decline)
        try await wait(session, slot: slot, phase: .interrupted)
        let resolved = await session.snapshot()
        XCTAssertTrue(resolved.approvals.isEmpty)
        await session.stop()
    }

    func testReadOnlyTurnRejectsRelativeWorkspace() async throws {
        let session = try await makeSession()
        try await session.start()
        do {
            try await session.startTurn(
                slotID: AgentSlotID(1),
                userPrompt: "hold",
                modelID: "fixture",
                permission: .init(type: .safeRead),
                cwd: "."
            )
            XCTFail("Relative cwd must be rejected in read-only mode as well")
        } catch WorkspacePolicyError.pathNotAbsolute {}
        await session.stop()
    }

    func testSameCoordinatorReconnectCreatesFreshServerThread() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/mock_app_server.py")
        let process = CodexProcessSupervisor()
        let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let session = CodexSessionCoordinator(
            transport: process,
            modelCatalogStore: CodexModelCatalogStore(fileURL: cache)
        )
        for _ in 0 ..< 2 {
            try await process.start(executablePath: "/usr/bin/python3", arguments: ["-u", fixture.path])
            try await session.start()
            try await session.startTurn(
                slotID: AgentSlotID(1),
                userPrompt: "complete",
                modelID: "fixture",
                permission: .init(type: .safeRead)
            )
            try await wait(session, slot: AgentSlotID(1), phase: .completed)
            await process.stop()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await session.snapshot().phase != .failed,
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            let state = await session.snapshot()
            XCTAssertEqual(state.phase, .failed)
            await session.rpc.stop()
        }
        await session.stop()
    }

    func testFailedTurnIsNotReportedAsCompleted() async throws {
        let session = try await makeSession()
        try await session.start()
        try await session.startTurn(
            slotID: AgentSlotID(1),
            userPrompt: "fail",
            modelID: "fixture",
            permission: .init(type: .safeRead)
        )
        try await wait(session, slot: AgentSlotID(1), phase: .failed)
        await session.stop()
    }

    func testStopAllResetsAllEightActiveSlots() async throws {
        let session = try await makeSession()
        try await session.start()
        for index in 1 ... 8 {
            try await session.startTurn(
                slotID: AgentSlotID(index),
                userPrompt: "hold",
                modelID: "fixture",
                permission: .init(type: .safeRead)
            )
        }
        await session.stop()
        let stopped = await session.snapshot()
        XCTAssertTrue(stopped.states.values.allSatisfy { $0.phase == .idle })
        XCTAssertTrue(stopped.approvals.isEmpty)
    }

    func testProtocolAndStateMachineSoak() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["BCR_CODEX_SOAK_SECONDS"] ?? "1") ?? 1
        let session = try await makeSession()
        try await session.start()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        var cycles = 0
        while ContinuousClock.now < deadline {
            let slot = AgentSlotID(cycles % 8 + 1)
            try await session.startTurn(
                slotID: slot,
                userPrompt: "complete",
                modelID: "fixture",
                permission: .init(type: .safeRead)
            )
            try await wait(session, slot: slot, phase: .completed)
            let state = await session.snapshot()
            XCTAssertEqual(state.phase, .ready)
            XCTAssertTrue(state.approvals.isEmpty)
            cycles += 1
        }
        await session.stop()
        print("Codex JSONL soak completed: \(seconds) seconds, \(cycles) turns, eight slots")
        XCTAssertGreaterThan(cycles, 0)
    }
}

private actor ApprovalFaultTransport: CodexLineTransport {
    enum Failure: Error { case unavailable }
    let base: CodexProcessSupervisor
    var failures: Int
    init(base: CodexProcessSupervisor, failures: Int) { self.base = base; self.failures = failures }
    func readLine() async throws -> String? { try await base.readLine() }
    func sendLine(_ line: String) async throws {
        let envelope = try CodexEnvelope.decodeJSON(line)
        if envelope.method == nil, envelope.result?.objectValue?["decision"] != nil, failures > 0 {
            failures -= 1
            throw Failure.unavailable
        }
        try await base.sendLine(line)
    }

    func close() async { await base.close() }
}
