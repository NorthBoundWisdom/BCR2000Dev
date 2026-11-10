import BCRAgentCore
import Foundation
import Network

struct MCPHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct MCPHTTPParseError: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// Bounded HTTP/1.1 framing. No chunked transfer or pipelining is advertised or accepted.
enum MCPHTTPParser {
    static func parse(_ data: Data) throws -> MCPHTTPRequest? {
        guard data.count <= 1_064_964 else { throw MCPHTTPParseError(reason: "请求超过大小上限") }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16_384 else { throw MCPHTTPParseError(reason: "HTTP 头过长") }
            return nil
        }
        guard separator.lowerBound <= 16_384,
              let text = String(data: data[..<separator.lowerBound], encoding: .utf8)
        else {
            throw MCPHTTPParseError(reason: "HTTP 头无效")
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1" else { throw MCPHTTPParseError(reason: "仅支持 HTTP/1.1") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw MCPHTTPParseError(reason: "HTTP 头格式无效")
            }
            let key = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                  key.utf8.allSatisfy({ (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 }),
                  !value.contains("\r"), !value.contains("\n"), headers[key] == nil
            else {
                throw MCPHTTPParseError(reason: "HTTP 头重复或无效")
            }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil else { throw MCPHTTPParseError(reason: "不支持 Transfer-Encoding") }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let parsed = Int(raw),
                  parsed <= 1_048_576 else { throw MCPHTTPParseError(reason: "Content-Length 无效") }
            length = parsed
        } else if request[0] == "POST" {
            throw MCPHTTPParseError(reason: "POST 必须包含 Content-Length")
        } else { length = 0 }
        let count = data.distance(from: separator.upperBound, to: data.endIndex)
        guard count <= length else { throw MCPHTTPParseError(reason: "不支持 HTTP 管线或多余请求数据") }
        guard count == length else { return nil }
        return MCPHTTPRequest(method: String(request[0]), path: String(request[1]), headers: headers,
                              body: Data(data[separator.upperBound...]))
    }
}

@MainActor
final class MCPHTTPServer {
    enum State: Equatable {
        case stopped, starting, listening(UInt16), failed(String)
    }

    private(set) var state: State = .stopped
    let router: MCPRouter
    var onChange: (() -> Void)?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var startContinuation: CheckedContinuation<UInt16, any Error>?
    private var startTimeout: Task<Void, Never>?
    private var generation = UUID()
    private var token = ""
    private var port: UInt16 = 0

    init(router: MCPRouter) { self.router = router }

    /// Port zero is only used by isolated loopback tests. The settings controller rejects it.
    func start(port: UInt16, token: String) async throws -> UInt16 {
        stop()
        guard !token.isEmpty else { throw MCPHTTPParseError(reason: "缺少 Bearer token") }
        self.token = token
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let generation = self.generation
        state = .starting
        onChange?()
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    switch state {
                    case .ready:
                        guard let bound = self.listener?.port?.rawValue, bound > 0 else {
                            self.fail("监听未返回有效端口")
                            return
                        }
                        self.port = bound
                        self.state = .listening(bound)
                        self.startTimeout?.cancel()
                        self.startTimeout = nil
                        self.startContinuation?.resume(returning: bound)
                        self.startContinuation = nil
                        self.onChange?()
                    case let .failed(error), let .waiting(error):
                        self.fail("MCP 监听失败：\(error.localizedDescription)")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)
            startTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.fail("MCP 监听启动超时")
            }
        }
    }

    func stop() {
        generation = UUID()
        startTimeout?.cancel()
        startTimeout = nil
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        listener?.cancel()
        listener = nil
        for timeout in timeouts.values { timeout.cancel() }
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        timeouts.removeAll()
        token = ""
        router.stop()
        state = .stopped
        onChange?()
    }

    private func fail(_ message: String) {
        let pending = startContinuation
        startContinuation = nil
        stop()
        state = .failed(message)
        pending?.resume(throwing: MCPHTTPParseError(reason: message))
        router.service.record("http", succeeded: false, detail: message)
        onChange?()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        timeouts[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard self?.connections[id] != nil else { return }
            self?.router.service.record("http", succeeded: false, detail: "请求接收超时")
            self?.close(id)
        }
        receive(id, accumulated: Data())
    }

    private func receive(_ id: UUID, accumulated: Data) {
        connections[id]?
            .receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
                Task { @MainActor [weak self] in
                    guard let self, self.connections[id] != nil else { return }
                    if error != nil { self.close(id); return }
                    var buffer = accumulated
                    if let data { buffer.append(data) }
                    do {
                        if let request = try MCPHTTPParser.parse(buffer) {
                            self.timeouts.removeValue(forKey: id)?.cancel()
                            self.respond(id, to: request)
                        } else if complete { self.close(id) }
                        else { self.receive(id, accumulated: buffer) }
                    } catch {
                        self.router.service.record("http", succeeded: false, detail: error.localizedDescription)
                        self.send(id, reply: MCPReply(status: 400))
                    }
                }
            }
    }

    private func respond(_ id: UUID, to request: MCPHTTPRequest) {
        guard request.path == "/mcp" else { send(id, reply: MCPReply(status: 404)); return }
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            reject(id, status: 403, detail: "Host 不属于本机 MCP 端点")
            return
        }
        if let raw = request.headers["origin"] {
            guard let origin = URLComponents(string: raw), origin.scheme == "http",
                  ["127.0.0.1", "localhost"].contains(origin.host?.lowercased() ?? ""),
                  origin.port == Int(port), origin.user == nil, origin.password == nil,
                  origin.query == nil, origin.fragment == nil, origin.path.isEmpty
            else {
                reject(id, status: 403, detail: "Origin 不允许")
                return
            }
        }
        guard let authorization = request.headers["authorization"], authorization.prefix(7).lowercased() == "bearer ",
              constantTimeEqual(String(authorization.dropFirst(7)), token)
        else {
            reject(id, status: 401, detail: "Bearer 鉴权失败")
            return
        }
        if request.method == "DELETE" {
            guard request.headers["mcp-protocol-version"] == MCPVersions.legacy else {
                send(id, reply: MCPReply(status: 405)); return
            }
            send(id, reply: router.deleteSession(request.headers["mcp-session-id"]))
            return
        }
        guard request.method == "POST" else { send(id, reply: MCPReply(status: 405)); return }
        guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
            .lowercased() == "application/json"
        else {
            send(id, reply: MCPReply(status: 415)); return
        }
        let accept = request.headers["accept"]?.lowercased() ?? ""
        guard accept.contains("application/json"), accept.contains("text/event-stream") else {
            send(id, reply: MCPReply(status: 406)); return
        }
        let reply = router.handle(request.body, headers: request.headers)
        send(id, reply: reply)
        onChange?()
    }

    private func reject(_ id: UUID, status: Int, detail: String) {
        router.service.record("http", succeeded: false, detail: detail)
        send(id, reply: MCPReply(status: status))
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func send(_ id: UUID, reply: MCPReply) {
        guard let connection = connections[id] else { return }
        let body: Data
        do { body = try reply.body.map { try JSONEncoder().encode($0) } ?? Data() }
        catch {
            router.service.record("http", succeeded: false, detail: "MCP 响应编码失败")
            close(id)
            return
        }
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
                      415: "Unsupported Media Type", 429: "Too Many Requests"][reply.status] ?? "Error"
        var header = "HTTP/1.1 \(reply.status) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        if reply.status == 401 { header += "WWW-Authenticate: Bearer\r\n" }
        if reply.status == 405 { header += "Allow: POST, DELETE\r\n" }
        if let sessionID = reply.sessionID { header += "Mcp-Session-Id: \(sessionID)\r\n" }
        var response = Data((header + "\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                if error != nil { self?.router.service.record("http", succeeded: false, detail: "MCP 响应发送失败") }
                self?.close(id)
            }
        })
    }

    private func close(_ id: UUID) {
        timeouts.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
