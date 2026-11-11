import AppKit
import BCRAgentCore
import Combine
import Foundation
import Security

@MainActor
protocol MCPCredentialStore: AnyObject {
    func loadOrCreate() async throws -> String
}

@MainActor
final class KeychainMCPCredentialStore: MCPCredentialStore {
    private let service = "dev.bcragentconsole.mcp"
    private let account = "loopback-bearer"

    func loadOrCreate() async throws -> String {
        let service = self.service, account = self.account
        return try await Task.detached(priority: .userInitiated) {
            try Self.readOrCreate(service: service, account: account)
        }.value
    }

    private nonisolated static func readOrCreate(service: String, account: String) throws -> String {
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service, kSecAttrAccount as String: account]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8),
                  value.utf8.count == 64,
                  value.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
            else {
                throw MCPHTTPParseError(reason: L10n.text("Keychain 中的 MCP 凭据无效"))
            }
            return value
        }
        guard status == errSecItemNotFound
        else { throw MCPHTTPParseError(reason: L10n.text("读取 Keychain 失败（\(status)）")) }
        var random = [UInt8](repeating: 0, count: 32)
        let randomStatus = random.withUnsafeMutableBytes { SecRandomCopyBytes(
            kSecRandomDefault,
            $0.count,
            $0.baseAddress!
        ) }
        guard randomStatus == errSecSuccess
        else { throw MCPHTTPParseError(reason: L10n.text("生成 MCP 凭据失败（\(randomStatus)）")) }
        let value = random.map { String(format: "%02x", Int($0)) }.joined()
        var item = identity
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw MCPHTTPParseError(reason: L10n.text("保存 MCP 凭据失败（\(added)）")) }
        return value
    }
}

struct MCPSettings: Codable, Equatable, Sendable {
    var version = 1
    var enabled = false
    var port = 8787
    var permissions = MCPPermissions()

    func validate() throws {
        guard version == 1 else { throw MCPHTTPParseError(reason: L10n.text("MCP 设置版本不受支持")) }
        guard (1_024 ... 65_535).contains(port)
        else { throw MCPHTTPParseError(reason: L10n.text("MCP 端口必须为 1024–65535")) }
        guard !permissions.configurationWrite || permissions.parameterWrite else {
            throw MCPHTTPParseError(reason: L10n.text("只读模式不能开启配置写入"))
        }
        guard (1 ... 10_000).contains(permissions.writesPerSecond)
        else { throw MCPHTTPParseError(reason: L10n.text("写入限额必须为每秒 1–10000")) }
    }
}

@MainActor
final class MCPController: ObservableObject {
    @Published private(set) var settings = MCPSettings()
    @Published private(set) var error: String?
    @Published private(set) var isStarting = false
    private var generation = UUID()
    let service: AgentControlService
    let server: MCPHTTPServer
    private let store: JSONFileStore<MCPSettings>
    private let credentials: any MCPCredentialStore
    let integrationTest: Bool

    init(session: SurfaceSession, store: JSONFileStore<MCPSettings>,
         credentials: any MCPCredentialStore = KeychainMCPCredentialStore(), integrationTest: Bool = false)
    {
        self.store = store
        self.credentials = credentials
        self.integrationTest = integrationTest
        service = AgentControlService(session: session)
        server = MCPHTTPServer(router: MCPRouter(service: service))
        do {
            if let loaded = try store.load() { try loaded.validate(); settings = loaded }
        } catch { self.error = L10n.text("MCP 设置读取失败：\(error.localizedDescription)") }
        service.permissions = settings.permissions
        service.onChange = { [weak self] in self?.objectWillChange.send() }
        server.onChange = { [weak self] in
            guard let self else { return }
            if case let .failed(message) = self.server.state { self.error = message }
            self.objectWillChange.send()
        }
        server.router.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    var isListening: Bool {
        if case .listening = server.state { return true }
        return false
    }

    var status: String {
        if isStarting { return L10n.text("MCP 等待启动") }
        if error != nil { return L10n.text("MCP 错误") }
        switch server.state {
        case .stopped: return L10n.text("MCP 关闭")
        case .starting: return L10n.text("MCP 启动中")
        case .listening:
            return server.router.sessionCount > 0 ? L10n.text("MCP 监听中 · \(server.router.sessionCount) 会话") : L10n
                .text("MCP 监听中")
        case .failed: return L10n.text("MCP 错误")
        }
    }

    var endpoint: String { "http://127.0.0.1:\(settings.port)/mcp" }

    func restore() async {
        if settings.enabled { await start() }
    }

    func setEnabled(_ enabled: Bool) async {
        generation = UUID()
        isStarting = false
        error = nil
        settings.enabled = enabled
        if !enabled { server.stop() }
        do { try store.save(settings) }
        catch { self.error = L10n.text("MCP 设置保存失败：\(error.localizedDescription)"); return }
        if enabled { await start() }
    }

    func apply(_ draft: MCPSettings) async {
        var candidate = draft
        candidate.enabled = settings.enabled
        do {
            try candidate.validate()
            try store.save(candidate)
            let portChanged = candidate.port != settings.port
            settings = candidate
            service.permissions = candidate.permissions
            error = nil
            if settings.enabled, portChanged {
                generation = UUID()
                await start()
            }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        generation = UUID()
        isStarting = false
        server.stop()
        settings.enabled = false
        do { try store.save(settings); error = nil }
        catch { self.error = L10n.text("MCP 已停止，但设置保存失败：\(error.localizedDescription)") }
    }

    func copyToken() async {
        do {
            guard settings.enabled,
                  !isStarting else { throw MCPHTTPParseError(reason: L10n.text("请先启用 MCP 服务并等待启动完成")) }
            let token = try await credentials.loadOrCreate()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(token, forType: .string) else {
                throw MCPHTTPParseError(reason: L10n.text("无法复制 MCP 凭据"))
            }
        } catch { self.error = error.localizedDescription }
    }

    func copyConnectionCommand() async {
        do {
            guard settings.enabled,
                  !isStarting else { throw MCPHTTPParseError(reason: L10n.text("请先启用 MCP 服务并等待启动完成")) }
            let token = try await credentials.loadOrCreate()
            let body: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("server/discover"),
                "params": .object(["_meta": .object([
                    "io.modelcontextprotocol/protocolVersion": .string(MCPVersions.current),
                    "io.modelcontextprotocol/clientCapabilities": .object([:])
                ])])
            ])
            let command = "curl -X POST '\(endpoint)' -H 'Authorization: Bearer \(token)' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: \(MCPVersions.current)' -H 'Mcp-Method: server/discover' --data '\(try body.jsonText)'"
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(command, forType: .string) else {
                throw MCPHTTPParseError(reason: L10n.text("无法复制连接命令"))
            }
        } catch { self.error = error.localizedDescription }
    }

    private func start() async {
        let requestGeneration = generation
        isStarting = true
        defer { if generation == requestGeneration { isStarting = false } }
        do {
            try settings.validate()
            let token = try await credentials.loadOrCreate()
            guard generation == requestGeneration, settings.enabled else { return }
            _ = try await server.start(port: UInt16(settings.port), token: token)
            if generation == requestGeneration { error = nil }
        } catch {
            if generation == requestGeneration, settings.enabled { self.error = error.localizedDescription }
        }
    }
}
