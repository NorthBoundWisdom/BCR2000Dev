import Foundation

public struct MCPReply: Sendable {
    public let status: Int
    public let body: JSONValue?
    public let sessionID: String?

    public init(status: Int = 200, body: JSONValue? = nil, sessionID: String? = nil) {
        self.status = status
        self.body = body
        self.sessionID = sessionID
    }
}

/// Implements the modern, stateless MCP protocol and the standardized legacy handshake.
/// Authentication, HTTP framing and Origin checks belong to the app transport.
@MainActor
public final class MCPRouter {
    public let service: AgentControlService
    public var onChange: (@MainActor () -> Void)?
    public var sessionCount: Int { sessions.count }
    private struct LegacySession {
        var initialized: Bool
        var seen: Date
    }

    private var sessions: [String: LegacySession] = [:]
    private let now: @MainActor () -> Date
    private let serverInfo: JSONValue = .object(["name": .string("bcr-console"), "version": .string("1.0.0")])

    public init(service: AgentControlService, now: @escaping @MainActor () -> Date = { .now }) {
        self.service = service
        self.now = now
    }

    public func stop() {
        sessions.removeAll()
        onChange?()
    }

    public func deleteSession(_ id: String?) -> MCPReply {
        guard let id, sessions.removeValue(forKey: id) != nil else { return MCPReply(status: 404) }
        onChange?()
        return MCPReply()
    }

    public func handle(_ data: Data, headers: [String: String]) -> MCPReply {
        let message: JSONValue
        do { message = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { return rpcError(-32700, "Parse error", id: .null, status: 400) }
        guard let object = message.objectValue,
              object["jsonrpc"] == .string("2.0"),
              let method = object["method"]?.stringValue, !method.isEmpty
        else {
            return rpcError(-32600, "Invalid Request", id: .null, status: 400)
        }
        let requestID = object["id"]
        if let requestID {
            switch requestID {
            case .string, .number: break
            default: return rpcError(-32600, "Invalid request id", id: .null, status: 400)
            }
        }
        let id = requestID ?? .null
        guard object["params"] == nil || object["params"]?.objectValue != nil else {
            return rpcError(-32602, "params must be an object", id: id)
        }
        let params = object["params"]?.objectValue ?? [:]
        let meta = params["_meta"]?.objectValue
        let declaredVersion = meta?["io.modelcontextprotocol/protocolVersion"]?.stringValue
        let headerVersion = headers["mcp-protocol-version"]
        let modern = declaredVersion != nil || headerVersion == MCPVersions.current
        if modern {
            guard let declaredVersion, declaredVersion == headerVersion,
                  headers["mcp-method"] == method,
                  meta?["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil
            else {
                return rpcError(-32020, "Required MCP metadata or mirrored headers do not match", id: id, status: 400)
            }
            guard declaredVersion == MCPVersions.current else {
                return rpcError(-32022, "Unsupported protocol version", id: id, status: 400,
                                data: .object(["supported": .array(MCPVersions.supported.map(JSONValue.string)),
                                               "requested": .string(declaredVersion)]))
            }
            if method == "tools/call" {
                guard let name = params["name"]?.stringValue,
                      decodeHeader(headers["mcp-name"]) == name
                else {
                    return rpcError(-32020, "Mcp-Name does not match params.name", id: id, status: 400)
                }
            }
        } else if method == "initialize" {
            guard requestID != nil,
                  params["protocolVersion"]?.stringValue != nil,
                  let info = params["clientInfo"]?.objectValue,
                  info["name"]?.stringValue != nil, info["version"]?.stringValue != nil,
                  params["capabilities"]?.objectValue != nil
            else {
                return rpcError(-32602, "Invalid initialize parameters", id: id)
            }
            expireSessions()
            guard sessions.count < 32 else { return rpcError(-32000, "Session capacity exceeded", id: id, status: 429) }
            let sessionID = UUID().uuidString
            sessions[sessionID] = LegacySession(initialized: false, seen: now())
            onChange?()
            return MCPReply(body: response(id: id, result: .object([
                "protocolVersion": .string(MCPVersions.legacy),
                "serverInfo": serverInfo,
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])])
            ])), sessionID: sessionID)
        } else {
            expireSessions()
            guard let sessionID = headers["mcp-session-id"], var session = sessions[sessionID] else {
                return rpcError(
                    -32000,
                    "Unknown or missing MCP session",
                    id: id,
                    status: headers["mcp-session-id"] == nil ? 400 : 404
                )
            }
            guard headerVersion == MCPVersions.legacy else {
                return rpcError(-32602, "MCP-Protocol-Version must match the initialized session", id: id, status: 400)
            }
            if method == "notifications/initialized", requestID == nil {
                session.initialized = true
                session.seen = now()
                sessions[sessionID] = session
                onChange?()
                return MCPReply(status: 202)
            }
            guard session.initialized else { return rpcError(-32002, "Session is not initialized", id: id) }
            session.seen = now()
            sessions[sessionID] = session
        }

        guard requestID != nil else { return MCPReply(status: 400) }
        let result: JSONValue
        switch method {
        case "server/discover" where modern:
            result = .object([
                "supportedVersions": .array(MCPVersions.supported.map(JSONValue.string)),
                "capabilities": .object(["tools": .object([:])]),
                "instructions": .string("Local BCR parameters; writes obey permissions, agentWritable and rate limits.")
            ])
        case "ping": result = .object([:])
        case "tools/list": result = .object(["tools": .array(MCPToolCatalog.tools)])
        case "tools/call":
            guard let name = params["name"]?.stringValue, name.utf8.count <= 128 else {
                return rpcError(-32602, "Tool name is required", id: id)
            }
            do { result = try service.call(name, arguments: params["arguments"] ?? .object([:])).rpcValue }
            catch { return rpcError(-32603, "Could not encode tool result", id: id) }
        default:
            return rpcError(-32601, "Method not found", id: id, status: modern ? 404 : 200)
        }
        return MCPReply(body: response(id: id, result: result, modern: modern))
    }

    private func response(id: JSONValue, result: JSONValue, modern: Bool = false) -> JSONValue {
        guard var result = result.objectValue else {
            return .object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object([
                                "code": .number(-32603),
                                "message": .string("Result must be an object")
                            ])])
        }
        if modern {
            result["resultType"] = .string("complete")
            result["_meta"] = .object(["io.modelcontextprotocol/serverInfo": serverInfo])
        }
        return .object(["jsonrpc": .string("2.0"), "id": id, "result": .object(result)])
    }

    private func rpcError(_ code: Int, _ message: String, id: JSONValue, status: Int = 200,
                          data: JSONValue? = nil) -> MCPReply
    {
        var error: [String: JSONValue] = ["code": .number(code), "message": .string(message)]
        if let data { error["data"] = data }
        return MCPReply(status: status, body: .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(error)]))
    }

    private func decodeHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        if value.hasPrefix("=?base64?"), value.hasSuffix("?=") {
            return Data(base64Encoded: String(value.dropFirst(9).dropLast(2))).flatMap { String(
                data: $0,
                encoding: .utf8
            ) }
        }
        return value.unicodeScalars.allSatisfy { (0x21 ... 0x7e).contains($0.value) } ? value : nil
    }

    private func expireSessions() {
        let time = now()
        sessions = sessions.filter { time.timeIntervalSince($0.value.seen) < 1_800 }
    }
}
