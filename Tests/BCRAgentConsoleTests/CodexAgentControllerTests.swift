import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole

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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
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

    func testConnectionFailureIsVisibleAndDoesNotFallBackToMock() async throws {
        let controller = CodexAgentController(directory: FileManager.default.temporaryDirectory)
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
