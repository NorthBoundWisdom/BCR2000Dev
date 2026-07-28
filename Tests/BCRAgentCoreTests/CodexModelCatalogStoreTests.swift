import Foundation
import XCTest
@testable import BCRAgentCore

final class CodexModelCatalogStoreTests: XCTestCase {
    func testCatalogPersistedWithMetadataAndEfforts() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "codex-model-catalog-tests-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: path)
        }

        let store = CodexModelCatalogStore(fileURL: path)
        let capability = CodexModelCapability(
            id: "model-x",
            displayName: "Model X",
            isDefault: true,
            defaultReasoningEffort: "high",
            supportedReasoningEfforts: ["low", "high"],
            metadata: ["provider": .string("openai"), "metadataTag": .string("v1")],
            hidden: false
        )

        try await store.save([capability])
        let loaded = try await store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0], capability)
        XCTAssertEqual(loaded[0].metadata["provider"], .string("openai"))
        XCTAssertEqual(loaded[0].supportedReasoningEfforts, ["low", "high"])
    }
}
