import Foundation
import XCTest
@testable import BCRAgentCore

final class CodexSessionCoordinatorTests: XCTestCase {
    func testStartLoadsModelsThroughPaginatedModelListAndCachesCatalog() async throws {
        let transport = InMemoryJSONLTransport(maxBufferedLines: 16)
        let catalogURL = FileManager.default.temporaryDirectory
            .appending(path: "codex-session-coordinator-catalog-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: catalogURL)
        }
        let catalogStore = CodexModelCatalogStore(fileURL: catalogURL)
        let coordinator = CodexSessionCoordinator(transport: transport, modelCatalogStore: catalogStore)

        let startTask = Task {
            try await coordinator.start()
        }

        let initializeEnvelope = try await firstSentEnvelope(from: transport)
        let initializeID = try XCTUnwrap(initializeEnvelope.id)
        await transport.enqueueIncoming(
            try CodexEnvelope(
                id: initializeID,
                result: .object(["capabilities": .object([:])])
            ).encodeJSON()
        )

        let initializedEnvelope = try await firstSentEnvelope(from: transport)
        XCTAssertEqual(initializedEnvelope.method, CodexMethod.initialized.rawValue)

        let accountReadEnvelope = try await firstSentEnvelope(from: transport)
        let accountID = try XCTUnwrap(accountReadEnvelope.id)
        await transport.enqueueIncoming(
            try CodexEnvelope(
                id: accountID,
                result: .object(["account": .string("demo-user")])
            ).encodeJSON()
        )

        let modelRequest = try await firstSentEnvelope(from: transport)
        let firstModelListID = try XCTUnwrap(modelRequest.id)
        await transport.enqueueIncoming(
            try CodexEnvelope(
                id: firstModelListID,
                result: .object([
                    "models": .array([
                        .object([
                            "id": .string("model-visible"),
                            "displayName": .string("Model Visible"),
                            "isDefault": .bool(true),
                            "defaultReasoningEffort": .string("low"),
                            "supportedReasoningEfforts": .array([.string("low"), .string("high")]),
                            "metadata": .object(["provider": .string("openai")])
                        ]),
                        .object([
                            "id": .string("model-hidden"),
                            "displayName": .string("Model Hidden"),
                            "isDefault": .bool(false),
                            "hidden": .bool(true),
                        ])
                    ]),
                    "nextCursor": .string("cursor-2")
                ])
            ).encodeJSON()
        )

        let secondModelRequest = try await firstSentEnvelope(from: transport)
        let secondModelListID = try XCTUnwrap(secondModelRequest.id)
        await transport.enqueueIncoming(
            try CodexEnvelope(
                id: secondModelListID,
                result: .object([
                    "models": .array([
                        .object([
                            "id": .string("model-extra"),
                            "displayName": .string("Model Extra"),
                            "isDefault": .bool(false),
                            "defaultReasoningEffort": .string("medium"),
                            "supportedReasoningEfforts": .array([.string("medium")]),
                            "metadata": .object(["provider": .string("openai-beta")])
                        ])
                    ]),
                ])
            ).encodeJSON()
        )

        try await startTask.value

        let phase = await coordinator.connectionPhase
        XCTAssertEqual(phase, .ready)

        let visibleModels = await coordinator.availableModels
        XCTAssertEqual(visibleModels.map(\.id), ["model-visible", "model-extra"])
        XCTAssertFalse(visibleModels.contains(where: { $0.id == "model-hidden" }))

        let cached = try await catalogStore.load()
        XCTAssertEqual(cached.map(\.id).sorted(), ["model-extra", "model-hidden", "model-visible"])
        let visible = cached.first(where: { $0.id == "model-visible" })
        XCTAssertEqual(visible?.metadata["provider"], .string("openai"))
    }
}

private func firstSentEnvelope(
    from transport: InMemoryJSONLTransport,
    timeoutMilliseconds: UInt64 = 500
) async throws -> CodexEnvelope {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while true {
        if let line = await transport.consumeNextSentLine() {
            return try CodexEnvelope.decodeJSON(line)
        }

        if ContinuousClock.now >= deadline {
            throw NSError(
                domain: "CodexSessionCoordinatorTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未收到预期的协议输出"]
            )
        }

        try await Task.sleep(for: .milliseconds(5))
    }
}
