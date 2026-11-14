import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

@MainActor
final class SurfaceAgentIntentTests: XCTestCase {
    private var mockTime = 0.0
    private func model() -> ConsoleViewModel {
        let stores = ConsoleStores.temporary()
        return ConsoleViewModel(stores: stores, startsMIDI: false, codexFactory: {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "BCRAgentCoreTests/Fixtures/mock_app_server.py")
            let process = CodexProcessSupervisor()
            try await process.start(executablePath: "/usr/bin/python3", arguments: ["-u", fixture.path])
            return CodexSessionCoordinator(transport: process, modelCatalogStore: CodexModelCatalogStore(
                fileURL: stores.configuration.fileURL.deletingLastPathComponent().appending(path: "catalog.json")
            ))
        }, mockClock: { self.mockTime }, automaticallyAdvancesMock: false)
    }

    private func advance(_ model: ConsoleViewModel, to time: Double) throws {
        mockTime = time
        try XCTUnwrap(model.mockAgents).advance()
    }

    private func wait(_ model: ConsoleViewModel, state: AgentRunState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.slots[0].state != state,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.slots[0].state, state)
    }

    func testSurfacePressWhileCodexAwaitsApprovalOnlyNotifiesAndKeepsLED() async throws {
        let model = model()
        model.codex.workspace = FileManager.default.temporaryDirectory.path
        await model.codex.selectBackend(.codex)
        await model.codex.connect()
        model.codex.prompt = "approval"
        model.performPrimaryAction(AgentSlotID(1))
        try await wait(model, state: .waitingApproval)
        let pending = model.codex.approvals
        let led = model.mock.value(of: .button(row: 1, 1))
        model.press(.button(row: 1, 1)) // Mock surface feeds the same onTriggerAgent device-intent boundary.
        XCTAssertEqual(model.codex.approvals, pending)
        XCTAssertTrue(model.codex.respondingApprovals.isEmpty)
        XCTAssertNil(model.codex.reviewingApproval)
        XCTAssertEqual(model.slots[0].state, .waitingApproval)
        XCTAssertEqual(model.mock.value(of: .button(row: 1, 1)), led)
        XCTAssertEqual(model.notice?.text, L10n.text("请在 Agent 页查看详情后批准或拒绝"))
        model.performPrimaryAction(AgentSlotID(1))
        let request = try XCTUnwrap(model.codex.reviewingApproval)
        model.codex.markApprovalPresented(request)
        model.codex.approveReviewedRequest(request)
        try await wait(model, state: .completed)
        await model.codex.stopAll()
    }

    func testSurfacePressStartsAndInterruptsCodex() async throws {
        let model = model()
        model.codex.workspace = FileManager.default.temporaryDirectory.path
        await model.codex.selectBackend(.codex)
        await model.codex.connect()
        model.codex.prompt = "hold"
        model.press(.button(row: 1, 1))
        try await wait(model, state: .running)
        model.release(.button(row: 1, 1))
        try await Task.sleep(for: .milliseconds(260))
        model.press(.button(row: 1, 1))
        try await wait(model, state: .interrupted)
        XCTAssertEqual(model.codex.phase, .ready)
        await model.codex.stopAll()
    }

    func testSurfacePressStillApprovesMock() throws {
        let model = model()
        let id = AgentSlotID(1)
        model.start(id)
        try advance(model, to: 2.65)
        model.press(.button(row: 1, 1))
        XCTAssertEqual(model.slots[0].state, .running)
        model.mockAgents?.stopDriving()
    }

    func testMockPrimaryActionBranchesForEveryState() throws {
        let id = AgentSlotID(1)
        let expected: [(AgentRunState, AgentRunState)] = [
            (.idle, .queued), (.completed, .queued), (.interrupted, .queued), (.error, .queued),
            (.queued, .interrupted), (.running, .interrupted), (.waitingApproval, .running)
        ]
        XCTAssertEqual(Set(expected.map(\.0)), Set(AgentRunState.allCases))
        for (initial, next) in expected {
            mockTime = 0
            let model = model()
            switch initial {
            case .idle: break
            case .queued: model.start(id)
            case .running:
                model.start(id)
                try advance(model, to: 0.45)
            case .waitingApproval:
                model.start(id)
                try advance(model, to: 2.65)
            case .completed:
                model.start(id)
                try advance(model, to: 2.65)
                model.approve(id)
                try advance(model, to: 2.65 + 2.25)
            case .interrupted:
                model.start(id)
                model.interrupt(id)
            case .error:
                // Error is a published backend snapshot; the Mock has no failing task stage.
                var slots = AgentSlot.mockSlots()
                slots[0].state = .error
                model.applyAgentSlots(slots, changed: id)
            }
            model.performPrimaryAction(id)
            XCTAssertEqual(model.slots[0].state, next, initial.rawValue)
            if initial == .waitingApproval { XCTAssertEqual(model.slots[0].progress, 0.64) }
            if next == .queued { XCTAssertEqual(model.slots[0].progress, 0) }
            model.mockAgents?.stopDriving()
        }
    }

    func testFailedPluginInitializationRejectsActionsVisiblyAndFailsMCPCommand() throws {
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false,
                                     mockClock: { .nan }, automaticallyAdvancesMock: false)
        XCTAssertNil(model.mockAgents)
        XCTAssertNotNil(model.notice)
        model.performPrimaryAction(AgentSlotID(1))
        XCTAssertEqual(model.notice?.text, L10n.text("Agent 服务不可用"))
        let action = try XCTUnwrap(model.mcp.service.onAgentAction)
        for name in ["start_agent", "interrupt_agent", "stop_all_agents"] {
            XCTAssertThrowsError(try action(name, AgentSlotID(1)))
        }
    }
}
