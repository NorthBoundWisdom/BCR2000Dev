import Foundation

public enum CodexSessionCoordinatorError: Error, LocalizedError, Sendable {
    case invalidState(String)
    case malformedPayload(String)
    case missingThreadID
    case missingTurnID
    case modelUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidState(message):
            "会话状态异常：\(message)"
        case let .malformedPayload(message):
            "响应异常：\(message)"
        case .missingThreadID:
            "缺少 threadId"
        case .missingTurnID:
            "缺少 turnId"
        case .modelUnavailable:
            "模型不可用"
        }
    }
}

public enum CodexConnectionPhase: String, Codable, Sendable {
    case stopped
    case launching
    case initializing
    case ready
    case failed
}

public actor CodexSessionCoordinator {
    public let rpc: CodexRPCClient
    private let modelCatalogStore: CodexModelCatalogStore

    public var onStateChange: (@Sendable (CodexConnectionPhase) -> Void)?

    public private(set) var connectionPhase: CodexConnectionPhase = .stopped
    public private(set) var account: String?
    public private(set) var availableModels: [CodexModelCapability] = []

    private let stateMachine = CodexSessionStateMachine()
    private let approvalGate = CodexApprovalGate()
    private var threadBySlot: [AgentSlotID: String] = [:]
    private var slotByThread: [String: AgentSlotID] = [:]

    private func loadCachedModelCatalog() async {
        guard let cached = try? await modelCatalogStore.load() else {
            return
        }
        availableModels = cached.filter { !$0.hidden }
    }

    public init(rpc: CodexRPCClient) {
        self.init(rpc: rpc, modelCatalogStore: CodexModelCatalogStore())
    }

    public init(rpc: CodexRPCClient, modelCatalogStore: CodexModelCatalogStore) {
        self.rpc = rpc
        self.modelCatalogStore = modelCatalogStore
    }

    public init(transport: CodexLineTransport) {
        self.init(transport: transport, modelCatalogStore: CodexModelCatalogStore())
    }

    public init(transport: CodexLineTransport, modelCatalogStore: CodexModelCatalogStore) {
        self.init(rpc: CodexRPCClient(transport: transport), modelCatalogStore: modelCatalogStore)
    }

    public func start() async throws {
        connectionPhase = .launching
        onStateChange?(.launching)

        await rpc.start()
        await rpc.setEventHandlers(
            onServerRequest: { [weak self] envelope in
                await self?.onServerEnvelope(envelope)
            },
            onNotification: { [weak self] envelope in
                await self?.onServerEnvelope(envelope)
            }
        )
        await loadCachedModelCatalog()

        do {
            try await handshake()
            try await refreshModelCatalog()
            connectionPhase = .ready
            onStateChange?(.ready)
        } catch {
            connectionPhase = .failed
            onStateChange?(.failed)
            await rpc.stop()
            throw error
        }
    }

    public func stop() async {
        connectionPhase = .stopped
        onStateChange?(.stopped)
        threadBySlot.removeAll()
        slotByThread.removeAll()
        await approvalGate.clearAll()
        await rpc.stop()
    }

    public func startTurn(
        slotID: AgentSlotID,
        userPrompt: String,
        modelID: String,
        effortID: String? = nil,
        permission: CodexPermissionPolicy,
        timeoutMs: Int? = nil
    ) async throws {
        guard connectionPhase == .ready else {
            throw CodexSessionCoordinatorError.invalidState("connection not ready")
        }
        guard availableModels.contains(where: { $0.id == modelID }) else {
            throw CodexSessionCoordinatorError.modelUnavailable
        }

        let threadID: String

        if let existing = threadBySlot[slotID] {
            _ = try await rpc.sendRequest(
                .threadResume,
                params: .object(["threadId": .string(existing)])
            )
            threadID = existing
        } else {
            let response = try await rpc.sendRequest(
                .threadStart,
                params: .object(["slot": .number(slotID.rawValue)])
            )
            guard let fetchedThreadID = response.result?.value(for: "threadId")?.stringValue else {
                throw CodexSessionCoordinatorError.missingThreadID
            }
            threadID = fetchedThreadID
            threadBySlot[slotID] = threadID
            slotByThread[threadID] = slotID
            try await stateMachine.bindThread(slotID: slotID, threadID: threadID)
        }

        let intent = CodexTurnIntent(
            modelID: modelID,
            effortID: effortID,
            permission: permission,
            priority: 0,
            timeoutMs: timeoutMs
        )

        let response = try await rpc.sendRequest(
            .turnStart,
            params: buildTurnStartParams(threadID: threadID, prompt: userPrompt, intent: intent)
        )

        guard let turnID = response.result?.value(for: "turnId")?.stringValue else {
            throw CodexSessionCoordinatorError.missingTurnID
        }

        try await stateMachine.onTurnStart(slotID: slotID, threadID: threadID, turnID: turnID)
    }

    public func interruptTurn(slotID: AgentSlotID) async throws {
        guard let snapshot = await stateMachine.snapshot(slotID: slotID) else {
            throw CodexSessionCoordinatorError.invalidState("unknown slot")
        }
        guard let threadID = threadBySlot[slotID], let turnID = snapshot.turnID else {
            throw CodexSessionCoordinatorError.invalidState("no active turn")
        }

        _ = try await rpc.sendRequest(
            .turnInterrupt,
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID)
            ])
        )
        try await stateMachine.onInterrupt(slotID: slotID)
    }

    public func onServerEnvelope(_ envelope: CodexEnvelope) async {
        guard let event = try? envelope.asServerEvent() else {
            return
        }

        switch event {
        case .turnStarted:
            _ = try? await stateMachine.handle(event: event)

        case .turnCompleted:
            _ = try? await stateMachine.handle(event: event)

        case let .commandExecutionRequestApproval(requestID, _, threadID, _):
            await routeApprovalRequest(requestID: requestID, threadID: threadID, kind: .commandExecutionRequestApproval)
            _ = try? await stateMachine.handle(event: event)

        case let .fileChangeRequestApproval(requestID, _, threadID, _):
            await routeApprovalRequest(requestID: requestID, threadID: threadID, kind: .fileChangeRequestApproval)
            _ = try? await stateMachine.handle(event: event)

        case .serverRequest, .notification:
            break
        }
    }

    public func sendApproval(
        requestID: String,
        slotID: AgentSlotID,
        visibleSlotID: AgentSlotID,
        decision: CodexApprovalDecision
    ) async throws {
        let shouldSend = try await approvalGate.resolveAgain(
            requestID: requestID,
            by: slotID,
            visibleSlotID: visibleSlotID,
            decision: decision
        )
        guard shouldSend else {
            return
        }

        let response = CodexEnvelope(
            id: .string(requestID),
            result: .object(["approved": .bool(decision == .approve)])
        )
        try await rpc.sendEnvelope(response)
    }

    private func handshake() async throws {
        connectionPhase = .initializing
        onStateChange?(.initializing)

        _ = try await rpc.sendRequest(
            .initialize,
            params: .object([
                "protocolVersion": .string("2025-03-26"),
                "clientInfo": .object([
                    "name": .string("BCRAgentConsole"),
                    "version": .string("0.1.0")
                ])
            ])
        )

        try await rpc.sendNotification(.initialized)

        let accountEnvelope = try await rpc.sendRequest(.accountRead)
        if let object = accountEnvelope.result?.objectValue {
            account = object["account"]?.stringValue ?? object["name"]?.stringValue
        }
    }

    private func refreshModelCatalog() async throws {
        var nextCursor: String?
        var gathered: [CodexModelCapability] = []

        while true {
            let payload: JSONValue
            if let cursor = nextCursor, !cursor.isEmpty {
                payload = .object(["cursor": .string(cursor)])
            } else {
                payload = .null
            }

            let response = try await rpc.sendRequest(.modelList, params: payload)
            let page = try CodexModelListPage(from: response.result ?? .null)
            gathered.append(contentsOf: page.models)

            if let cursor = page.nextCursor, !cursor.isEmpty {
                nextCursor = cursor
            } else {
                break
            }
        }

        availableModels = gathered.filter { !$0.hidden }
        try await modelCatalogStore.save(gathered)
    }

    private func routeApprovalRequest(
        requestID: String,
        threadID: String,
        kind: CodexServerRequestKind
    ) async {
        guard let slotID = slotByThread[threadID] else {
            return
        }
        await approvalGate.clearExpiredRequests()

        await approvalGate.registerRequest(
            requestID,
            kind: kind,
            for: slotID,
            visibleSlotID: slotID
        )
    }

    private func buildTurnStartParams(
        threadID: String,
        prompt: String,
        intent: CodexTurnIntent
    ) -> JSONValue {
        var intentPayload: [String: JSONValue] = [
            "permission": intent.permission.jsonValue,
            "priority": .number(intent.priority)
        ]

        if let modelID = intent.modelID {
            intentPayload["modelId"] = .string(modelID)
        }
        if let effortID = intent.effortID {
            intentPayload["effortId"] = .string(effortID)
        }
        if let timeoutMs = intent.timeoutMs {
            intentPayload["timeoutMs"] = .number(timeoutMs)
        }

        return .object([
            "threadId": .string(threadID),
            "input": .string(prompt),
            "intent": .object(intentPayload)
        ])
    }
}
