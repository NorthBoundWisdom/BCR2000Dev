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
import Foundation
import XCTest
import enum AgentPlugin.AgentRunState
import struct AgentPlugin.AgentStateMachine

final class AgentCompatibilityFacadeTests: XCTestCase {
    func testSharedStateAndEveryTransitionMatchFrozenHostPolicy() {
        let shared: AgentRunState = .running
        XCTAssertEqual(shared, .running)
        let explicit: Set<String> = ["idle.queued", "completed.queued", "interrupted.queued", "error.queued",
                                     "queued.running", "queued.interrupted", "running.waitingApproval",
                                     "running.completed", "running.interrupted", "waitingApproval.running",
                                     "waitingApproval.interrupted"]
        for from in AgentRunState.allCases {
            for to in AgentRunState.allCases {
                XCTAssertEqual(AgentStateMachine.allows(from: from, to: to),
                               from == to || to == .error || explicit.contains(from.rawValue + "." + to.rawValue))
            }
        }
    }

    func testLegacyDateNameTextAndCodableProjectionRemainIntact() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1234)
        let slot = AgentSlotPresentation(id: AgentSlotID(2), name: "Custom name", state: .running, progress: 0.34,
                                         statusText: "Custom status", lastUpdated: date)
        let data = try AgentSlotArchive.encode(slot)
        XCTAssertEqual(try AgentSlotArchive.decode(data), slot)
        let object = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
        XCTAssertEqual(Set(object.keys), ["id", "name", "state", "progress", "statusText", "lastUpdated"])
        XCTAssertEqual(object["name"], .string("Custom name"))
        XCTAssertEqual(object["statusText"], .string("Custom status"))
        XCTAssertEqual(object["lastUpdated"]?.finiteNumber, 1234)
        var shared = try AgentStateMachine(slotCount: 2, at: 1234)
        try shared.transition(2, to: .queued, at: 1234)
        try shared.transition(2, to: .running, progress: slot.progress, at: 1234)
        let core = try shared.transition(2, to: .waitingApproval, progress: 0.6, statusKey: "approval", at: 1235)
        let updated = AgentSlotPresentation(
            core: core,
            name: slot.name,
            statusText: "approval",
            lastUpdated: date.addingTimeInterval(1)
        )
        XCTAssertEqual(core.lastUpdated, 1235)
        XCTAssertEqual(updated.name, slot.name)
        XCTAssertEqual(updated.lastUpdated, date.addingTimeInterval(1))
        XCTAssertEqual(updated.statusText, "approval")
        XCTAssertThrowsError(try shared.transition(2, to: .idle, at: 1235)) { error in
            XCTAssertEqual(error as? PluginError, .init(code: .invalidTransition,
                                                        fields: [
                                                            "index": .number(2),
                                                            "from": .string("waitingApproval"),
                                                            "to": .string("idle")
                                                        ]))
        }
    }
}
