import Foundation

public enum CodexRPCError: Error, LocalizedError, Sendable {
    case disconnected
    case timeout(CodexRequestID)
    case invalidMessage(String)
    case transport(String)
    case responseWithoutRequest(CodexRequestID)
    case requestRejected(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .disconnected:
            "Codex 连接未建立"
        case let .timeout(id):
            "请求 \(id) 超时"
        case let .invalidMessage(text):
            "无效消息：\(text)"
        case let .transport(text):
            "传输错误：\(text)"
        case let .responseWithoutRequest(id):
            "未匹配到请求 ID \(id) 的 pending 回调"
        case let .requestRejected(code, message):
            "服务端拒绝（code: \(code)）：\(message)"
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
    private var nextRequestID = 1
    private var readTask: Task<Void, Never>?
    private var pending: [CodexRequestID: PendingRequest] = [:]
    private let defaultTimeout: Duration

    public init(
        transport: CodexLineTransport,
        defaultTimeout: Duration = .seconds(30)
    ) {
        self.transport = transport
        self.defaultTimeout = defaultTimeout
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

        for pending in pending.values {
            pending.complete(continuation: nil, error: CodexRPCError.disconnected)
        }
        pending.removeAll()
        await transport.close()
    }

    public func sendRequest(
        _ method: CodexMethod,
        params: JSONValue? = nil,
        timeout: Duration? = nil
    ) async throws -> CodexEnvelope {
        guard running else {
            throw CodexRPCError.disconnected
        }
        let id = nextID()
        let envelope = CodexEnvelope(
            id: id,
            method: method.rawValue,
            params: params,
        )
        let line = try envelope.encodeJSON()
        try await transport.sendLine(line)

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutValue = timeout ?? defaultTimeout
            let timeoutTask = Task {
                try? await Task.sleep(for: timeoutValue)
                Task { await self.failPendingRequest(id, error: CodexRPCError.timeout(id)) }
            }
            pending[id] = PendingRequest(
                id: id,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
        }
    }

    public func sendNotification(_ method: CodexMethod, params: JSONValue? = nil) async throws {
        let line = try CodexEnvelope(method: method.rawValue, params: params).encodeJSON()
        try await transport.sendLine(line)
    }

    private func nextID() -> CodexRequestID {
        let id = nextRequestID
        nextRequestID += 1
        return .number(id)
    }

    private func readLoop() async {
        while !Task.isCancelled, running {
            do {
                guard let line = try await transport.readLine() else {
                    await stop()
                    break
                }
                let message = try CodexEnvelope.decodeJSON(line)
                if message.isResponse {
                    await deliverResponse(message)
                    continue
                }
                await dispatchServerMessage(message)
            } catch is CancellationError {
                break
            } catch {
                await stop()
            }
        }
    }

    private func deliverResponse(_ message: CodexEnvelope) async {
        guard let id = message.id else {
            return
        }
        guard let pending = pending.removeValue(forKey: id) else {
            return
        }
        pending.cancelTimeout()
        if let error = message.error {
            pending.complete(
                continuation: nil,
                error: CodexRPCError.requestRejected(code: error.code, message: error.message)
            )
            return
        }
        pending.complete(continuation: nil, error: nil, response: message)
    }

    private func dispatchServerMessage(_ message: CodexEnvelope) async {
        if let handler = onServerRequest, message.id != nil {
            await handler(message)
            return
        }
        if let handler = onNotification, message.method != nil {
            await handler(message)
        }
    }

    private func failPendingRequest(_ id: CodexRequestID, error: Error) async {
        guard let pending = pending.removeValue(forKey: id) else {
            return
        }
        pending.cancelTimeout()
        pending.complete(continuation: nil, error: error)
    }
}

private final class PendingRequest: @unchecked Sendable {
    private let id: CodexRequestID
    private let continuation: CheckedContinuation<CodexEnvelope, Error>
    private let timeoutTask: Task<Void, Never>

    init(
        id: CodexRequestID,
        continuation: CheckedContinuation<CodexEnvelope, Error>,
        timeoutTask: Task<Void, Never>
    ) {
        self.id = id
        self.continuation = continuation
        self.timeoutTask = timeoutTask
    }

    func complete(
        continuation _: CheckedContinuation<CodexEnvelope, Error>? = nil,
        error: Error?,
        response: CodexEnvelope? = nil
    ) {
        if let error {
            continuation.resume(throwing: error)
            return
        }
        continuation.resume(returning: response ?? CodexEnvelope())
    }

    func cancelTimeout() {
        timeoutTask.cancel()
    }
}
