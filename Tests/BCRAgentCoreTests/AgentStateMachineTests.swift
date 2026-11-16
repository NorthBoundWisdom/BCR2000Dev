import struct AgentPlugin.AgentStateMachine
import SurfacePluginContracts
@testable import BCRFoundation
@testable import BCRCodexAdapter
@testable import BCRSurfaceDomain
@testable import BCRExamples
@testable import BCRConfigurationAdapter
@testable import BCRMCPAdapter
@testable import BCRHTTPTransport
@testable import BCRCoreMIDIDriver
@testable import BCRPersistenceAdapter
import XCTest

final class AgentStateMachineTests: XCTestCase {
    func testMockLifecycleRequiresApprovalBeforeCompletion() throws {
        let slot = AgentSlotID(1)
        var machine = try AgentStateMachine()

        try machine.transition(slot.rawValue, to: .queued, progress: 0, statusKey: "queued", at: 0)
        try machine.transition(slot.rawValue, to: .running, progress: 0.1, statusKey: "running", at: 0)
        try machine.updateProgress(slot.rawValue, progress: 0.6, statusKey: "work", at: 0)
        try machine.transition(
            slot.rawValue,
            to: .waitingApproval,
            progress: 0.6,
            statusKey: "approval"
            , at: 0
        )
        try machine.transition(slot.rawValue, to: .running, progress: 0.7, statusKey: "approved", at: 0)
        try machine.transition(slot.rawValue, to: .completed, progress: 1, statusKey: "done", at: 0)

        XCTAssertEqual(machine.slot(slot.rawValue)?.state, .completed)
        XCTAssertEqual(machine.slot(slot.rawValue)?.progress, 1)
    }

    func testRejectsImpossibleIdleToCompletedTransition() throws {
        let slot = AgentSlotID(2)
        var machine = try AgentStateMachine()

        XCTAssertThrowsError(
            try machine.transition(slot.rawValue, to: .completed, statusKey: "invalid", at: 0)
        ) { error in
            XCTAssertEqual(
                error as? PluginError,
                .init(
                    code: .invalidTransition,
                    fields: ["index": .number(slot.rawValue), "from": .string("idle"), "to": .string("completed")]
                )
            )
        }
    }

    func testActiveStatesCanBeInterrupted() throws {
        for slotNumber in 1 ... 3 {
            let slot = AgentSlotID(slotNumber)
            var machine = try AgentStateMachine()
            try machine.transition(slot.rawValue, to: .queued, statusKey: "queued", at: 0)

            if slotNumber >= 2 {
                try machine.transition(slot.rawValue, to: .running, statusKey: "running", at: 0)
            }
            if slotNumber == 3 {
                try machine.transition(slot.rawValue, to: .waitingApproval, statusKey: "approval", at: 0)
            }

            try machine.transition(slot.rawValue, to: .interrupted, statusKey: "stopped", at: 0)
            XCTAssertEqual(machine.slot(slot.rawValue)?.state, .interrupted)
        }
    }
}
