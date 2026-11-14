import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

@MainActor
final class CodexAgentControllerTests: XCTestCase {
    private func controller(directory: URL) -> CodexAgentController {
        CodexAgentController(directory: directory) {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "BCRAgentCoreTests/Fixtures/mock_app_server.py")
            let process = CodexProcessSupervisor()
            try await process.start(executablePath: "/usr/bin/python3", arguments: ["-u", fixture.path])
            return CodexSessionCoordinator(transport: process,
                                           modelCatalogStore: CodexModelCatalogStore(fileURL: directory
                                               .appending(path: "catalog.json")))
        }
    }

    func testExplicitBackendConnectionTurnStopAndReconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = controller(directory: directory)
        controller.workspace = FileManager.default.temporaryDirectory.path
        XCTAssertEqual(controller.backend, .mock)
        await controller.selectBackend(.codex)
        await controller.connect()
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.modelID, "fixture")
        controller.prompt = "hold"
        controller.start(AgentSlotID(1))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.slots[0].state != .running, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.slots[0].state, .running)
        await controller.stopAll()
        XCTAssertEqual(controller.slots[0].state, .interrupted)
        XCTAssertEqual(controller.phase, .stopped)
        await controller.connect()
        XCTAssertEqual(controller.phase, .ready)
        await controller.selectBackend(.mock)
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertEqual(controller.backend, .mock)
    }

    private func waitFor(_ controller: CodexAgentController, phase: AgentRunState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.slots[0].state != phase,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.slots[0].state, phase)
    }

    func testPrimaryAndSlotApproveIntentsOnlyOpenReviewAndCannotAuthorize() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = controller(directory: directory)
        controller.workspace = FileManager.default.temporaryDirectory.path
        await controller.selectBackend(.codex)
        await controller.connect()
        controller.prompt = "approval"
        let slot = AgentSlotID(1)
        controller.start(slot)
        try await waitFor(controller, phase: .waitingApproval)
        let request = try XCTUnwrap(controller.approvals.first)
        controller.approveReviewedRequest(request)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(controller.respondingApprovals.isEmpty)
        controller.perform(slot)
        XCTAssertEqual(controller.reviewingApproval?.id, request.id)
        controller.approveReviewedRequest(request)
        XCTAssertTrue(controller.respondingApprovals.isEmpty)
        controller.markApprovalPresented(request)
        controller.perform(slot)
        controller.decide(slot, approve: true)
        XCTAssertTrue(controller.respondingApprovals.isEmpty)
        XCTAssertEqual(controller.slots[0].state, .waitingApproval)
        controller.approveReviewedRequest(request)
        try await waitFor(controller, phase: .completed)
        XCTAssertTrue(controller.approvals.isEmpty)
        XCTAssertNil(controller.reviewingApproval)
        await controller.stopAll()
    }

    func testReviewChoosesExactRequestAndRejectNeedsNoPresentation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = controller(directory: directory)
        controller.workspace = FileManager.default.temporaryDirectory.path
        await controller.selectBackend(.codex)
        await controller.connect()
        controller.prompt = "parallel_approval"
        controller.start(AgentSlotID(1))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.approvals.count < 2,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.approvals.count, 2)
        let second = try XCTUnwrap(controller.approvals.last)
        controller.reviewApproval(second.id)
        controller.markApprovalPresented(second)
        controller.approveReviewedRequest(second)
        while controller.approvals.count == 2,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.approvals.count, 1)
        XCTAssertEqual(controller.slots[0].state, .waitingApproval)
        let first = try XCTUnwrap(controller.approvals.first)
        XCTAssertNotEqual(first.id, second.id)
        controller.rejectApproval(first.id)
        try await waitFor(controller, phase: .interrupted)
        XCTAssertTrue(controller.approvals.isEmpty)
        await controller.stopAll()
    }

    func testOldReviewCannotAuthorizeReusedRPCIDAfterReconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = controller(directory: directory)
        controller.workspace = FileManager.default.temporaryDirectory.path
        await controller.selectBackend(.codex)
        await controller.connect()
        controller.prompt = "approval"
        controller.start(AgentSlotID(1))
        try await waitFor(controller, phase: .waitingApproval)
        let old = try XCTUnwrap(controller.approvals.first)
        controller.reviewApproval(old.id)
        controller.markApprovalPresented(old)
        await controller.stopAll()
        await controller.connect()
        controller.start(AgentSlotID(1))
        try await waitFor(controller, phase: .waitingApproval)
        let current = try XCTUnwrap(controller.approvals.first)
        XCTAssertEqual(current.id, old.id)
        XCTAssertNotEqual(current.reviewToken, old.reviewToken)
        controller.reviewApproval(current.id)
        controller.markApprovalPresented(old)
        controller.approveReviewedRequest(old)
        XCTAssertTrue(controller.respondingApprovals.isEmpty)
        XCTAssertEqual(controller.slots[0].state, .waitingApproval)
        controller.markApprovalPresented(current)
        controller.approveReviewedRequest(current)
        try await waitFor(controller, phase: .completed)
        await controller.stopAll()
    }

    func testQueuedInterruptIsScopedToOneSlot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = controller(directory: directory)
        controller.workspace = FileManager.default.temporaryDirectory.path
        await controller.selectBackend(.codex)
        await controller.connect()
        controller.prompt = "hold"
        controller.start(AgentSlotID(2))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.slots[1].state != .running,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        controller.prompt = "delayed_hold"
        controller.start(AgentSlotID(1))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.slots[0].state, .queued)
        controller.interrupt(AgentSlotID(1))
        try await waitFor(controller, phase: .interrupted)
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.slots[1].state, .running)
        XCTAssertNil(controller.error)
        await controller.stopAll()
    }

    func testImmediateQueuedInterruptDoesNotCancelNextStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = controller(directory: directory)
        controller.workspace = FileManager.default.temporaryDirectory.path
        await controller.selectBackend(.codex)
        await controller.connect()
        controller.prompt = "hold"
        controller.start(AgentSlotID(1))
        controller.interrupt(AgentSlotID(1))
        try await waitFor(controller, phase: .interrupted)
        try await Task.sleep(for: .milliseconds(20))
        controller.start(AgentSlotID(1))
        try await waitFor(controller, phase: .running)
        XCTAssertNil(controller.error)
        await controller.stopAll()
    }

    func testPreferencesPersistWithoutPromptOrAutomaticConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CodexAgentController(directory: directory)
        controller.selectExecutable(URL(fileURLWithPath: "/bin/cat"))
        controller.workspace = FileManager.default.temporaryDirectory.path
        controller.modelID = "fixture-model"; controller.effort = "low"; controller.allowWorkspaceWrites = true
        controller.prompt = "private unsaved task"
        await controller.selectBackend(.codex)
        XCTAssertTrue(controller.savePreferences())
        let data = try Data(contentsOf: directory.appending(path: "codex-preferences.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private unsaved task"))
        let reopened = CodexAgentController(directory: directory)
        XCTAssertEqual(reopened.backend, .codex)
        XCTAssertEqual(reopened.executable, "/bin/cat")
        XCTAssertEqual(reopened.workspace, controller.workspace)
        XCTAssertEqual(reopened.modelID, "fixture-model")
        XCTAssertEqual(reopened.effort, "low")
        XCTAssertTrue(reopened.allowWorkspaceWrites)
        XCTAssertEqual(reopened.prompt, "")
        XCTAssertEqual(reopened.phase, .stopped)
    }

    func testRelativeExecutableIsRejectedInsteadOfGuessingGUIPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CodexAgentController(directory: directory)
        controller.workspace = FileManager.default.temporaryDirectory.path
        await controller.selectBackend(.codex)
        controller.executable = "codex"
        await controller.connect()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertNotNil(controller.error)
        XCTAssertEqual(controller.executable, "codex")
    }

    func testConnectionFailureIsVisibleAndDoesNotFallBackToMock() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CodexAgentController(directory: directory)
        controller.workspace = FileManager.default.temporaryDirectory.path
        controller.executable = "/nonexistent-bcr-codex-fixture"
        await controller.selectBackend(.codex)
        await controller.connect()
        XCTAssertEqual(controller.backend, .codex)
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertNotNil(controller.error)
    }

    func testMultiSlotPublicationUpdatesEveryLED() {
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false)
        var slots = model.slots
        slots[0].state = .running
        slots[1].state = .waitingApproval
        model.applyAgentSlots(slots, changed: AgentSlotID(1))
        XCTAssertEqual(model.mock.value(of: .button(row: 1, 1)), AgentRunState.running.feedbackValue)
        XCTAssertEqual(model.mock.value(of: .button(row: 1, 2)), AgentRunState.waitingApproval.feedbackValue)
    }
}
