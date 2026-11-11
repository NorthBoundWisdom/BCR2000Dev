import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
final class SurfaceAgentIntentTests: XCTestCase {
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
        })
    }

    private func wait(_ model: ConsoleViewModel, state: AgentRunState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
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
        try model.agentMachine.transition(id, to: .queued)
        try model.agentMachine.transition(id, to: .running)
        try model.agentMachine.transition(id, to: .waitingApproval)
        model.applyAgentSlots(model.agentMachine.slots, changed: id)
        model.press(.button(row: 1, 1))
        XCTAssertEqual(model.slots[0].state, .running)
        model.mockTasks.values.forEach { $0.cancel() }
    }
}
