import Foundation
import XCTest
import enum AgentPlugin.AgentRunState
import struct AgentPlugin.AgentStateMachine
@testable import BCRAgentCore

final class AgentCompatibilityFacadeTests: XCTestCase {
    func testLegacyStateIsTheSharedEnumAndEveryTransitionUsesSharedPolicy() {
        let shared: AgentPlugin.AgentRunState = BCRAgentCore.AgentRunState.running
        XCTAssertEqual(shared, .running)
        for from in BCRAgentCore.AgentRunState.allCases {
            for to in BCRAgentCore.AgentRunState.allCases {
                XCTAssertEqual(BCRAgentCore.AgentStateMachine.allows(from: from, to: to),
                               AgentPlugin.AgentStateMachine.allows(from: from, to: to))
            }
        }
    }

    func testLegacyDateNameTextAndCodableProjectionRemainIntact() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1234)
        let slot = AgentSlot(id: AgentSlotID(2), name: "Custom name", state: .running, progress: 0.34,
                             statusText: "Custom status", lastUpdated: date)
        let data = try JSONEncoder().encode(slot)
        XCTAssertEqual(try JSONDecoder().decode(AgentSlot.self, from: data), slot)
        let object = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
        XCTAssertEqual(Set(object.keys), ["id", "name", "state", "progress", "statusText", "lastUpdated"])
        XCTAssertEqual(object["name"], .string("Custom name"))
        XCTAssertEqual(object["statusText"], .string("Custom status"))
        XCTAssertEqual(object["lastUpdated"]?.finiteNumber, 1234)
        var legacy = BCRAgentCore.AgentStateMachine(slots: [slot])
        let updated = try legacy.transition(slot.id, to: .waitingApproval, progress: 0.6,
                                            statusText: "approval", now: date.addingTimeInterval(1))
        XCTAssertEqual(updated.name, slot.name)
        XCTAssertEqual(updated.lastUpdated, date.addingTimeInterval(1))
        XCTAssertEqual(updated.statusText, "approval")
        XCTAssertThrowsError(try legacy.transition(slot.id, to: .idle)) { error in
            XCTAssertEqual(error as? AgentStateMachineError,
                           .invalidTransition(slot: slot.id, from: .waitingApproval, to: .idle))
        }
    }
}
