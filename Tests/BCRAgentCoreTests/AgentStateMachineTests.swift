import XCTest
@testable import BCRAgentCore

final class AgentStateMachineTests: XCTestCase {
    func testMockLifecycleRequiresApprovalBeforeCompletion() throws {
        let slot = AgentSlotID(1)
        var machine = AgentStateMachine()

        try machine.transition(slot, to: .queued, progress: 0, statusText: "queued")
        try machine.transition(slot, to: .running, progress: 0.1, statusText: "running")
        try machine.updateProgress(slot, progress: 0.6, statusText: "work")
        try machine.transition(
            slot,
            to: .waitingApproval,
            progress: 0.6,
            statusText: "approval"
        )
        try machine.transition(slot, to: .running, progress: 0.7, statusText: "approved")
        try machine.transition(slot, to: .completed, progress: 1, statusText: "done")

        XCTAssertEqual(machine.slot(slot)?.state, .completed)
        XCTAssertEqual(machine.slot(slot)?.progress, 1)
    }

    func testRejectsImpossibleIdleToCompletedTransition() {
        let slot = AgentSlotID(2)
        var machine = AgentStateMachine()

        XCTAssertThrowsError(
            try machine.transition(slot, to: .completed, statusText: "invalid")
        ) { error in
            XCTAssertEqual(
                error as? AgentStateMachineError,
                .invalidTransition(slot: slot, from: .idle, to: .completed)
            )
        }
    }

    func testActiveStatesCanBeInterrupted() throws {
        for slotNumber in 1...3 {
            let slot = AgentSlotID(slotNumber)
            var machine = AgentStateMachine()
            try machine.transition(slot, to: .queued, statusText: "queued")

            if slotNumber >= 2 {
                try machine.transition(slot, to: .running, statusText: "running")
            }
            if slotNumber == 3 {
                try machine.transition(slot, to: .waitingApproval, statusText: "approval")
            }

            try machine.transition(slot, to: .interrupted, statusText: "stopped")
            XCTAssertEqual(machine.slot(slot)?.state, .interrupted)
        }
    }
}
