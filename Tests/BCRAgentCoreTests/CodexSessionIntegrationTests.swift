import Foundation
import XCTest
@testable import BCRAgentCore

@MainActor
final class CodexSessionIntegrationTests: XCTestCase {
    private func makeSession() async throws -> CodexSessionCoordinator {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/mock_app_server.py")
        let process = CodexProcessSupervisor()
        try await process.start(executablePath: "/usr/bin/python3", arguments: ["-u", fixture.path])
        let cache = FileManager.default.temporaryDirectory.appending(path: "bcr-catalog-\(UUID().uuidString).json")
        return CodexSessionCoordinator(transport: process, modelCatalogStore: CodexModelCatalogStore(fileURL: cache))
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
