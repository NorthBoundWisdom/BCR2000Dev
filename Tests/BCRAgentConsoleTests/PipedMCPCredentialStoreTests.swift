import Foundation
import XCTest
import BCRAgentCore
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

@MainActor
final class PipedMCPCredentialStoreTests: XCTestCase {
    func testConfigurationRestrictionIsPersistedByTheAppController() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore<MCPSettings>(fileURL: directory.appending(path: "mcp-settings.json"))
        var settings = MCPSettings()
        settings.permissions.configurationWrite = true
        try store.save(settings)
        let session = SurfaceSession(
            hardwareDevice: MockSurfaceDevice(),
            configuration: .robotArmDemo(), saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let controller = MCPController(session: session, store: store)
        XCTAssertFalse(controller.service.call("restrict_configuration_write").isError)
        XCTAssertFalse(controller.service.permissions.configurationWrite)
        XCTAssertFalse(try XCTUnwrap(store.load()).permissions.configurationWrite)
        XCTAssertTrue(controller.settings.permissions.parameterWrite)
    }

    func testExplicitPipeTokenIsKeptInMemory() async throws {
        let token = String(repeating: "a", count: 64)
        let store = try PipedMCPCredentialStore(data: Data(token.utf8))
        let actual = try await store.loadOrCreate()
        XCTAssertEqual(actual, token)
    }

    func testInvalidPipeDataIsRejectedWithoutEchoingInput() async {
        for data in [Data(), Data("fixture-secret".utf8), Data(repeating: 97, count: 65),
                     Data(repeating: 65, count: 64), Data(repeating: 255, count: 64)]
        {
            XCTAssertThrowsError(try PipedMCPCredentialStore(data: data)) { error in
                XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
            }
        }
    }
}
