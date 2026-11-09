#if DEBUG
import Foundation

/// Explicit debug-only native acceptance context. Production credentials and files are never used.
@MainActor
struct IntegrationTestContext {
    let directory: URL
    private let token: String

    init(environment: [String: String]) throws {
        guard let path = environment["BCR_INTEGRATION_DIRECTORY"], path.hasPrefix("/"), path != "/" else {
            throw MCPHTTPParseError(reason: "隔离测试需要绝对路径 BCR_INTEGRATION_DIRECTORY")
        }
        guard let token = environment["BCR_INTEGRATION_TOKEN"], token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MCPHTTPParseError(reason: "隔离测试需要 64 位十六进制测试凭据")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        self.token = token
    }

    var stores: ConsoleStores {
        ConsoleStores(
            hardwareMap: JSONFileStore(fileURL: directory.appending(path: "hardware-map.json")),
            configuration: JSONFileStore(fileURL: directory.appending(path: "surface-configuration.json"))
        )
    }

    var credentials: any MCPCredentialStore { IntegrationCredentials(token: token) }
}

@MainActor
private final class IntegrationCredentials: MCPCredentialStore {
    private let token: String
    init(token: String) { self.token = token }
    func loadOrCreate() async throws -> String { token }
}
#endif
