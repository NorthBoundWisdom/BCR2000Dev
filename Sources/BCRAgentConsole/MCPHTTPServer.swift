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
        guard data.count <= 1_064_964 else { throw MCPHTTPParseError(reason: L10n.text("请求超过大小上限")) }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16_384 else { throw MCPHTTPParseError(reason: L10n.text("HTTP 头过长")) }
            return nil
        }
        guard separator.lowerBound <= 16_384,
              let text = String(data: data[..<separator.lowerBound], encoding: .utf8)
        else {
            throw MCPHTTPParseError(reason: L10n.text("HTTP 头无效"))
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3,
              request[2] == "HTTP/1.1" else { throw MCPHTTPParseError(reason: L10n.text("仅支持 HTTP/1.1")) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw MCPHTTPParseError(reason: L10n.text("HTTP 头格式无效"))
            }
            let key = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                  key.utf8.allSatisfy({ (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 }),
                  !value.contains("\r"), !value.contains("\n"), headers[key] == nil
            else {
                throw MCPHTTPParseError(reason: L10n.text("HTTP 头重复或无效"))
            }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil
        else { throw MCPHTTPParseError(reason: L10n.text("不支持 Transfer-Encoding")) }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let parsed = Int(raw),
                  parsed <= 1_048_576 else { throw MCPHTTPParseError(reason: L10n.text("Content-Length 无效")) }
            length = parsed
        } else if request[0] == "POST" {
            throw MCPHTTPParseError(reason: L10n.text("POST 必须包含 Content-Length"))
        } else { length = 0 }
        let count = data.distance(from: separator.upperBound, to: data.endIndex)
        guard count <= length else { throw MCPHTTPParseError(reason: L10n.text("不支持 HTTP 管线或多余请求数据")) }
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

    private struct EventStream {
        let sessionID: String?
        var queue: [Data] = []
        var bytes = 0
        var sending = false
    }

    private var eventStreams: [UUID: EventStream] = [:]
    private var heartbeatTask: Task<Void, Never>?

    init(router: MCPRouter) {
        self.router = router
        _ = router.service.session.observeParameters { [weak self] batch in
            self?.broadcast(batch)
        }
        router.onSessionClosed = { [weak self] session in
            guard let self else { return }
            for (id, stream) in self.eventStreams where stream.sessionID == session { self.close(id) }
        }
    }

    /// Port zero is only used by isolated loopback tests. The settings controller rejects it.
    func start(port: UInt16, token: String) async throws -> UInt16 {
        stop()
        guard !token.isEmpty else { throw MCPHTTPParseError(reason: L10n.text("缺少 Bearer token")) }
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
                            self.fail(L10n.text("监听未返回有效端口"))
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
                        self.fail(L10n.text("MCP 监听失败：\(error.localizedDescription)"))
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
                self?.fail(L10n.text("MCP 监听启动超时"))
            }
        }
    }

    func stop() {
        generation = UUID()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        eventStreams.removeAll()
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
            self?.router.service.record("http", succeeded: false, detail: L10n.text("请求接收超时"))
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
            reject(id, status: 403, detail: L10n.text("Host 不属于本机 MCP 端点"))
            return
        }
        if let raw = request.headers["origin"] {
            guard let origin = URLComponents(string: raw), origin.scheme == "http",
                  ["127.0.0.1", "localhost"].contains(origin.host?.lowercased() ?? ""),
                  origin.port == Int(port), origin.user == nil, origin.password == nil,
                  origin.query == nil, origin.fragment == nil, origin.path.isEmpty
            else {
                reject(id, status: 403, detail: L10n.text("Origin 不允许"))
                return
            }
        }
        guard let authorization = request.headers["authorization"], authorization.prefix(7).lowercased() == "bearer ",
              constantTimeEqual(String(authorization.dropFirst(7)), token)
        else {
            reject(id, status: 401, detail: L10n.text("Bearer 鉴权失败"))
            return
        }
        if request.method == "GET" {
            guard request.headers["accept"]?.lowercased().contains("text/event-stream") == true else {
                send(id, reply: MCPReply(status: 406)); return
            }
            guard router.permitsEventStream(sessionID: request.headers["mcp-session-id"],
                                            version: request.headers["mcp-protocol-version"])
            else {
                send(id, reply: MCPReply(status: 400)); return
            }
            openEventStream(id, sessionID: request.headers["mcp-session-id"])
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

    private func openEventStream(_ id: UUID, sessionID: String?) {
        guard eventStreams.count < 16, let connection = connections[id] else {
            send(id, reply: MCPReply(status: 429)); return
        }
        eventStreams[id] = EventStream(sessionID: sessionID)
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Content-Type-Options: nosniff\r\n\r\n"
            .utf8)
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in if error != nil { self?.close(id) } }
        })
        // Every new stream receives a complete snapshot; reconnect never replays stale motion commands.
        sendBatch(router.service.session.parameterSnapshot(), to: id)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            Task { @MainActor [weak self] in self?.close(id) }
        }
        if heartbeatTask == nil {
            heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self else { return }
                    for id in Array(self.eventStreams.keys) { self.enqueueEvent(Data(": heartbeat\n\n".utf8), to: id) }
                }
            }
        }
    }

    private func broadcast(_ batch: ParameterChangeBatch) {
        for id in Array(eventStreams.keys) { sendBatch(batch, to: id) }
    }

    private func sendBatch(_ batch: ParameterChangeBatch, to id: UUID) {
        let message = JSONValue.object(["jsonrpc": .string("2.0"),
                                        "method": .string("notifications/bcr/parametersChanged"),
                                        "params": batch.jsonValue])
        do {
            let data = Data("id: \(batch.revision)\nevent: message\ndata: \(try message.jsonText)\n\n".utf8)
            enqueueEvent(data, to: id)
        } catch { close(id) }
    }

    private func enqueueEvent(_ data: Data, to id: UUID) {
        guard var stream = eventStreams[id] else { return }
        guard stream.bytes + data.count <= 65_536 else {
            router.service.record("sse", succeeded: false, detail: L10n.text("参数推送客户端读取过慢，连接已关闭"))
            close(id); return
        }
        stream.queue.append(data)
        stream.bytes += data.count
        eventStreams[id] = stream
        drainEvent(id)
    }

    private func drainEvent(_ id: UUID) {
        guard var stream = eventStreams[id], !stream.sending, !stream.queue.isEmpty,
              let connection = connections[id] else { return }
        let data = stream.queue.removeFirst()
        stream.sending = true
        eventStreams[id] = stream
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, var stream = self.eventStreams[id] else { return }
                if error != nil { self.close(id); return }
                stream.bytes -= data.count
                stream.sending = false
                self.eventStreams[id] = stream
                self.drainEvent(id)
            }
        })
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
            router.service.record("http", succeeded: false, detail: L10n.text("MCP 响应编码失败"))
            close(id)
            return
        }
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
                      415: "Unsupported Media Type", 429: "Too Many Requests"][reply.status] ?? "Error"
        var header = "HTTP/1.1 \(reply.status) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        if reply.status == 401 { header += "WWW-Authenticate: Bearer\r\n" }
        if reply.status == 405 { header += "Allow: GET, POST, DELETE\r\n" }
        if let sessionID = reply.sessionID { header += "Mcp-Session-Id: \(sessionID)\r\n" }
        var response = Data((header + "\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                if error !=
                    nil { self?.router.service.record("http", succeeded: false, detail: L10n.text("MCP 响应发送失败")) }
                self?.close(id)
            }
        })
    }

    private func close(_ id: UUID) {
        eventStreams[id] = nil
        if eventStreams.isEmpty { heartbeatTask?.cancel(); heartbeatTask = nil }
        timeouts.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}
