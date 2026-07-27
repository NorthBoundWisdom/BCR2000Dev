import XCTest
@testable import BCRAgentCore

final class CodexSessionStateMachineTests: XCTestCase {
    func testTurnStartedThenCompleted() async throws {
        let machine = CodexSessionStateMachine()
        let slot = AgentSlotID(1)

        try await machine.bindThread(slotID: slot, threadID: "thread-1")
        try await machine.onTurnStart(slotID: slot, threadID: "thread-1", turnID: "turn-1")

        var snapshot = await machine.snapshot(slotID: slot)
        XCTAssertEqual(snapshot?.phase, .running)
        XCTAssertEqual(snapshot?.turnID, "turn-1")

        try await machine.onApprovalRequired(slotID: slot, threadID: "thread-1", turnID: "turn-1")
        snapshot = await machine.snapshot(slotID: slot)
        XCTAssertEqual(snapshot?.phase, .awaitingApproval)

        try await machine.onTurnCompleted(threadID: "thread-1", turnID: "turn-1")
        snapshot = await machine.snapshot(slotID: slot)
        XCTAssertEqual(snapshot?.phase, .completed)
        XCTAssertNil(snapshot?.turnID)
    }

    func testCompletionWithUnknownThreadIsError() async {
        let machine = CodexSessionStateMachine()

        do {
            try await machine.onTurnCompleted(threadID: "unknown", turnID: "t")
            XCTFail("未知 threadId 应报错")
        } catch {
            XCTAssertTrue(error is CodexSessionStateMachineError)
        }
    }

    func testHandleCommandApprovalEventTransitionsStateToAwaitingApproval() async throws {
        let machine = CodexSessionStateMachine()
        let slotID = AgentSlotID(1)

        try await machine.bindThread(slotID: slotID, threadID: "thread-1")
        try await machine.onTurnStart(slotID: slotID, threadID: "thread-1", turnID: "turn-1")

        let event = CodexServerEvent.commandExecutionRequestApproval(
            requestID: "req-1",
            turnID: "turn-1",
            threadID: "thread-1",
            command: "rm -rf ."
        )
        try await machine.handle(event: event)

        let snapshot = await machine.snapshot(slotID: slotID)
        XCTAssertEqual(snapshot?.phase, .awaitingApproval)
    }
}
