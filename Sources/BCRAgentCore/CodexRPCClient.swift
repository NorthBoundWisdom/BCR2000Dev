import Foundation

public enum CodexRPCError: Error, LocalizedError, Sendable {
    case disconnected
    case timeout(CodexRequestID)
    case invalidMessage(String)
    case transport(String)
    case responseWithoutRequest(CodexRequestID)
    case requestRejected(code: Int, message: String)
    case malformedResponse(CodexRequestID)
    case unexpectedMessageShape(String)

    public var errorDescription: String? {
        switch self {
        case .disconnected:
            "Codex 连接未建立"
        case let .timeout(id):
            "请求 \(id.stringValue) 超时"
        case let .invalidMessage(text):
            "无效消息：\(text)"
        case let .transport(text):
            "传输错误：\(text)"
        case let .responseWithoutRequest(id):
            "未匹配到请求 ID \(id.stringValue) 的 pending 回调"
        case let .requestRejected(code, message):
            "服务端拒绝（code: \(code)）：\(message)"
        case let .malformedResponse(id):
            "响应 ID \(id.stringValue) 不包含 result 或 error"
        case let .unexpectedMessageShape(text):
            "异常消息结构：\(text)"
        }
    }
}

public actor CodexRPCClient {
    public typealias ServerRequestHandler = @Sendable (CodexEnvelope) async -> Void
    public typealias NotificationHandler = @Sendable (CodexEnvelope) async -> Void

    public var onServerRequest: ServerRequestHandler?
    public var onNotification: NotificationHandler?

    private let transport: CodexLineTransport
    private var running = false
    private var nextRequestIDValue = 1
    private var readTask: Task<Void, Never>?
    private var pending: [CodexRequestID: PendingRequest] = [:]
    private let defaultTimeout: Duration
    private let maxLineLength: Int

    public init(
        transport: CodexLineTransport,
        defaultTimeout: Duration = .seconds(30),
        maxLineLength: Int = 16_384
    ) {
        self.transport = transport
        self.defaultTimeout = defaultTimeout
        self.maxLineLength = max(maxLineLength, 1)
    }

    deinit {
        readTask?.cancel()
    }

    public func start() async {
        guard !running else {
            return
        }
        running = true
        readTask = Task { await self.readLoop() }
    }

    public func stop() async {
        guard running else {
            return
        }
        running = false
        readTask?.cancel()
        readTask = nil

        for request in pending.values {
            request.complete(error: CodexRPCError.disconnected)
        }
        pending.removeAll()
        await transport.close()
    }

    public func setEventHandlers(
        onServerRequest: ServerRequestHandler?,
        onNotification: NotificationHandler?
    ) {
        self.onServerRequest = onServerRequest
        self.onNotification = onNotification
    }

    public func sendRequest(
        _ method: CodexMethod,
        params: JSONValue? = nil,
        timeout: Duration? = nil
    ) async throws -> CodexEnvelope {
        guard running else {
            throw CodexRPCError.disconnected
        }

        let requestID = nextRequestID()
        let line = try CodexEnvelope(
            id: requestID,
            method: method.rawValue,
            params: params
        ).encodeJSON()

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutValue = timeout ?? defaultTimeout
            let timeoutTask = Task { [requestID, weak self] in
                try? await Task.sleep(for: timeoutValue)
                await self?.failPendingRequest(requestID, error: CodexRPCError.timeout(requestID))
            }
            pending[requestID] = PendingRequest(
                id: requestID,
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            Task { [requestID, line, weak self] in
                do {
                    try await self?.transport.sendLine(line)
                } catch {
                    await self?.failPendingRequest(requestID, error: CodexRPCError.transport(error.localizedDescription))
                }
            }
        }
    }

    public func sendNotification(_ method: CodexMethod, params: JSONValue? = nil) async throws {
        let line = try CodexEnvelope(method: method.rawValue, params: params).encodeJSON()
        try await transport.sendLine(line)
    }

    public func sendEnvelope(_ envelope: CodexEnvelope) async throws {
        try await transport.sendLine(envelope.encodeJSON())
    }

    private func nextRequestID() -> CodexRequestID {
        let id = nextRequestIDValue
        nextRequestIDValue += 1
        return .number(id)
    }

    private func readLoop() async {
        while !Task.isCancelled, running {
            do {
                guard let line = try await transport.readLine() else {
                    await stop()
                    break
                }
                let trimmed = line.trimmingCharacters(in: .newlines)
                if trimmed.isEmpty {
                    continue
                }
                if trimmed.utf8.count > maxLineLength {
                    await stopWithError(CodexRPCError.invalidMessage("行长度超限"))
                    break
                }

                let message: CodexEnvelope
                do {
                    message = try CodexEnvelope.decodeJSON(trimmed)
                } catch {
                    await stopWithError(CodexRPCError.invalidMessage(error.localizedDescription))
                    break
                }

                if message.isResponse {
                    await deliverResponse(message)
                    continue
                }

                if message.method != nil {
                    await dispatchServerMessage(message)
                    continue
                }

                await stopWithError(CodexRPCError.unexpectedMessageShape("缺少 method/id 结构"))
            } catch is CancellationError {
                break
            } catch {
                await stopWithError(CodexRPCError.transport(error.localizedDescription))
                break
            }
        }
    }

    private func stopWithError(_ error: CodexRPCError) async {
        for request in pending.values {
            request.complete(error: error)
        }
        pending.removeAll()
        await stop()
    }

    private func deliverResponse(_ message: CodexEnvelope) async {
        guard let id = message.id else {
            await failResponseWithoutId(message)
            return
        }

        guard let request = pending.removeValue(forKey: id) else {
            await stopWithError(CodexRPCError.responseWithoutRequest(id))
            return
        }
        request.cancelTimeout()

        if let errorPayload = message.error {
            request.complete(
                error: CodexRPCError.requestRejected(
                    code: errorPayload.code,
                    message: errorPayload.message
                )
            )
            return
        }

        guard message.result != nil || message.error != nil else {
            request.complete(error: CodexRPCError.malformedResponse(id))
            return
        }

        request.complete(response: message)
    }

    private func failResponseWithoutId(_ message: CodexEnvelope) async {
        await stopWithError(CodexRPCError.unexpectedMessageShape("响应缺少 id: \(message)"))
    }

    private func dispatchServerMessage(_ message: CodexEnvelope) async {
        if message.id != nil {
            if let handler = onServerRequest {
                await handler(message)
            } else {
                await sendServerRequestError(message)
            }
            return
        }

        if let handler = onNotification {
            await handler(message)
        }
    }

    private func sendServerRequestError(_ message: CodexEnvelope) async {
        guard let id = message.id else { return }
        let response = CodexEnvelope(
            id: id,
            error: CodexErrorPayload(
                code: -32601,
                message: "Server request unhandled"
            )
        )
        do {
            let payload = try response.encodeJSON()
            try await transport.sendLine(payload)
        } catch {
            await stopWithError(CodexRPCError.transport(error.localizedDescription))
        }
    }

    private func failPendingRequest(_ id: CodexRequestID, error: Error) async {
        guard let request = pending.removeValue(forKey: id) else {
            return
        }
        request.cancelTimeout()
        request.complete(error: error)
    }
}

private final class PendingRequest: @unchecked Sendable {
    private let continuation: CheckedContinuation<CodexEnvelope, Error>
    private let timeoutTask: Task<Void, Never>
    private var done = false

    init(
        id _: CodexRequestID,
        continuation: CheckedContinuation<CodexEnvelope, Error>,
        timeoutTask: Task<Void, Never>
    ) {
        self.continuation = continuation
        self.timeoutTask = timeoutTask
    }

    func complete(response: CodexEnvelope? = nil, error: Error? = nil) {
        guard !done else {
            return
        }
        done = true
        timeoutTask.cancel()

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: response ?? CodexEnvelope())
        }
    }

    func cancelTimeout() {
        timeoutTask.cancel()
    }
}
