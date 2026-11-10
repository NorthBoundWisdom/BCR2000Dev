#if DEBUG
    import Foundation
    import XCTest
    @testable import BCRAgentConsole

    @MainActor
    final class IntegrationTestContextTests: XCTestCase {
        func testContextUsesOnlyItsExplicitDirectoryAndInjectedCredential() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let token = String(repeating: "a", count: 64)
            let context = try IntegrationTestContext(environment: [
                "BCR_INTEGRATION_DIRECTORY": directory.path,
                "BCR_INTEGRATION_TOKEN": token
            ])
            XCTAssertEqual(
                context.stores.configuration.fileURL.deletingLastPathComponent().standardizedFileURL.path,
                directory.standardizedFileURL.path
            )
            XCTAssertNotEqual(context.stores.configuration.fileURL, ConsoleStores.standard.configuration.fileURL)
            let supplied = try await context.credentials.loadOrCreate()
            XCTAssertEqual(supplied, token)
            let model = ConsoleViewModel(stores: context.stores, startsMIDI: false,
                                         mcpCredentials: context.credentials, integrationTest: true)
            XCTAssertTrue(model.mcp.integrationTest)
            XCTAssertTrue(model.notice?.text.contains("隔离") == true)
        }

        func testInvalidIntegrationEnvironmentFailsInsteadOfUsingUserData() async {
            for values in [
                [:],
                ["BCR_INTEGRATION_DIRECTORY": "relative", "BCR_INTEGRATION_TOKEN": String(repeating: "a", count: 64)],
                ["BCR_INTEGRATION_DIRECTORY": "/", "BCR_INTEGRATION_TOKEN": String(repeating: "a", count: 64)],
                ["BCR_INTEGRATION_DIRECTORY": "/tmp/bcr-test", "BCR_INTEGRATION_TOKEN": "invalid"]
            ] { XCTAssertThrowsError(try IntegrationTestContext(environment: values)) }
        }
    }
#endif
