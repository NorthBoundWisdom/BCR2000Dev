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
            L10n.text("会话状态异常：\(message)")
        case let .malformedPayload(message):
            L10n.text("响应异常：\(message)")
        case .missingThreadID:
            L10n.text("缺少 threadId")
        case .missingTurnID:
            L10n.text("缺少 turnId")
        case .modelUnavailable:
            L10n.text("模型不可用")
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

public struct CodexPendingApproval: Equatable, Sendable, Identifiable {
    public let reviewToken = UUID()
    public let id: CodexRequestID
    public let slotID: AgentSlotID
    public let detail: String
    public let threadID: String
    public let turnID: String

    public init(id: CodexRequestID, slotID: AgentSlotID, detail: String, threadID: String, turnID: String) {
        self.id = id
        self.slotID = slotID
        self.detail = detail
        self.threadID = threadID
        self.turnID = turnID
    }
}

public struct CodexSessionSnapshot: Sendable {
    public let phase: CodexConnectionPhase
    public let states: [AgentSlotID: CodexSlotRuntimeState]
    public let approvals: [CodexPendingApproval]
    public let models: [CodexModelCapability]
    public let error: String?
}

public actor CodexSessionCoordinator {
    public let rpc: CodexRPCClient
    private let clientVersion: String
    private let modelCatalogStore: CodexModelCatalogStore
    public var onStateChange: (@Sendable (CodexConnectionPhase) -> Void)?
    private var onSnapshot: (@Sendable (CodexSessionSnapshot) -> Void)?
    public private(set) var connectionPhase: CodexConnectionPhase = .stopped
    public private(set) var account: String?
    public private(set) var availableModels: [CodexModelCapability] = []
    private let stateMachine = CodexSessionStateMachine()
    private let approvalWindow: TimeInterval?
    private var responding: Set<CodexRequestID> = []
    private let approvalGate = CodexApprovalGate()
    private var threadBySlot: [AgentSlotID: String] = [:]
    private var slotByThread: [String: AgentSlotID] = [:]
    private var seenApprovalIDs: Set<CodexRequestID> = []
    private var approvals: [CodexRequestID: CodexPendingApproval] = [:]
    private var startIDs: [AgentSlotID: UUID] = [:]
    private var cancelledStarts: Set<UUID> = []
    private var interrupting: Set<AgentSlotID> = []
    private var starting: Set<AgentSlotID> = []
    private var generation = 0
    private var lastError: String?

    public init(
        rpc: CodexRPCClient,
        modelCatalogStore: CodexModelCatalogStore = CodexModelCatalogStore(),
        approvalWindow: TimeInterval? = nil,
        clientVersion: String = "development"
    ) {
        self.rpc = rpc
        self.approvalWindow = approvalWindow
        self.clientVersion = clientVersion
        self.modelCatalogStore = modelCatalogStore
    }

    public init(
        transport: any CodexLineTransport,
        modelCatalogStore: CodexModelCatalogStore = CodexModelCatalogStore(),
        approvalWindow: TimeInterval? = nil,
        clientVersion: String = "development"
    ) {
        self.rpc = CodexRPCClient(transport: transport)
        self.approvalWindow = approvalWindow
        self.clientVersion = clientVersion
        self.modelCatalogStore = modelCatalogStore
    }

    public func setSnapshotHandler(_ handler: (@Sendable (CodexSessionSnapshot) -> Void)?) { onSnapshot = handler }
    public func snapshot() async -> CodexSessionSnapshot {
        var states = await stateMachine.allStates()
        let pending = approvals.values.filter { request in
            guard let state = states[request.slotID] else { return false }
            return state.threadID == request.threadID && state.turnID == request.turnID
                && (state.phase == .running || state.phase == .awaitingApproval)
        }
        // The request set is authoritative: asynchronous state-machine hops must never show
        // a slot as running while another request for that same turn still needs a decision.
        for slot in states.keys {
            if var state = states[slot], state.phase == .running || state.phase == .awaitingApproval {
                state.phase = pending.contains(where: { $0.slotID == slot }) ? .awaitingApproval : .running
                states[slot] = state
            }
        }
        return CodexSessionSnapshot(phase: connectionPhase, states: states,
                                    approvals: pending.sorted { $0.id.stringValue < $1.id.stringValue },
                                    models: availableModels, error: lastError)
    }

    private func publish() async {
        onStateChange?(connectionPhase)
        onSnapshot?(await snapshot())
    }

    private func check(_ expected: Int) throws {
        guard generation == expected, connectionPhase != .stopped, connectionPhase != .failed else {
            throw CancellationError()
        }
    }

    public func start() async throws {
        guard connectionPhase == .stopped || connectionPhase == .failed else {
            throw CodexSessionCoordinatorError.invalidState("already connected")
        }
        generation += 1
        let revision = generation
        connectionPhase = .initializing
        starting.removeAll(); startIDs.removeAll(); cancelledStarts.removeAll(); interrupting.removeAll()
        approvals.removeAll(); responding.removeAll(); seenApprovalIDs.removeAll()
        threadBySlot.removeAll(); slotByThread.removeAll()
        await approvalGate.clearAll()
        for slot in (1 ... 8).map({ AgentSlotID($0) }) { try? await stateMachine.reset(slotID: slot) }
        lastError = nil
        await publish()
        await rpc.setEventHandlers(onServerRequest: { [weak self] event in
            await self?.receive(event, generation: revision)
        }, onNotification: { [weak self] event in
            await self?.receive(event, generation: revision)
        })
        await rpc.setDisconnectHandler { [weak self] error in
            Task { await self?.disconnected(error, generation: revision) }
        }
        await rpc.start()
        do {
            _ = try await rpc.sendRequest(.initialize, params: .object([
                "clientInfo": .object(["name": .string("BCRAgentConsole"), "title": .string("BCR Agent Console"),
                                       "version": .string(clientVersion)])
            ]))
            try check(revision)
            try await rpc.sendNotification(.initialized)
            let accountReply = try await rpc.sendRequest(.accountRead)
            try check(revision)
            account = accountReply.result?.objectValue?["account"]?.stringValue
                ?? accountReply.result?.objectValue?["account"]?.objectValue?["email"]?.stringValue
            var gathered: [CodexModelCapability] = []
            var cursor: String?
            var seen: Set<String> = []
            repeat {
                let response = try await rpc.sendRequest(
                    .modelList,
                    params: .object(cursor.map { ["cursor": .string($0)] } ?? [:])
                )
                try check(revision)
                let page = try CodexModelListPage(from: response.result ?? .null)
                gathered.append(contentsOf: page.models)
                cursor = page.nextCursor
                if let cursor, !cursor.isEmpty, !seen.insert(cursor).inserted {
                    throw CodexSessionCoordinatorError.malformedPayload("repeated model cursor")
                }
            } while cursor?.isEmpty == false
            try await modelCatalogStore.save(gathered)
            try check(revision)
            availableModels = gathered.filter { !$0.hidden }
            connectionPhase = .ready
            await publish()
        } catch {
            if revision == generation, connectionPhase != .stopped {
                connectionPhase = .failed
                lastError = error.localizedDescription
                await rpc.stop()
                await publish()
            }
            throw error
        }
    }

    private func disconnected(_ error: String, generation revision: Int) async {
        guard revision == generation, connectionPhase != .stopped, connectionPhase != .failed else { return }
        connectionPhase = .failed
        lastError = error
        starting.removeAll()
        startIDs.removeAll(); cancelledStarts.removeAll(); interrupting.removeAll()
        approvals.removeAll()
        responding.removeAll()
        for (slot, state) in await stateMachine.allStates() {
            if let thread = state.threadID, let turn = state.turnID {
                try? await stateMachine.finish(threadID: thread, turnID: turn, phase: .failed, error: error)
            } else { try? await stateMachine.reset(slotID: slot) }
        }
        await publish()
    }

    public func stop() async {
        generation += 1
        connectionPhase = .stopped
        starting.removeAll()
        startIDs.removeAll(); cancelledStarts.removeAll(); interrupting.removeAll()
        approvals.removeAll()
        responding.removeAll()
        seenApprovalIDs.removeAll()
        threadBySlot.removeAll()
        slotByThread.removeAll()
        account = nil
        availableModels = []
        await approvalGate.clearAll()
        for slot in (1 ... 8).map({ AgentSlotID($0) }) { try? await stateMachine.reset(slotID: slot) }
        await rpc.stop()
        await publish()
    }

    public func startTurn(slotID: AgentSlotID, userPrompt: String, modelID: String, effortID: String? = nil,
                          permission: CodexPermissionPolicy, timeoutMs: Int? = nil, cwd: String? = nil,
                          startID: UUID = UUID()) async throws
    {
        guard connectionPhase == .ready, !starting.contains(slotID) else {
            throw CodexSessionCoordinatorError.invalidState("connection not ready or slot busy")
        }
        if let state = await stateMachine.snapshot(slotID: slotID),
           [.running, .awaitingApproval].contains(state.phase)
        {
            throw CodexSessionCoordinatorError.invalidState("slot busy")
        }
        guard let model = availableModels.first(where: { $0.id == modelID }),
              effortID == nil || model.supportedReasoningEfforts.contains(effortID!)
        else {
            throw CodexSessionCoordinatorError.modelUnavailable
        }
        let cwd = try cwd.map { try WorkspacePolicy.canonicalWorkspaceRoot($0).path }
        if permission.type == .workspaceWrite {
            try WorkspacePolicy.validateWorkspaceWrite(cwdPath: cwd, writableRoots: permission.writableRoots)
        }
        let revision = generation
        starting.insert(slotID)
        startIDs[slotID] = startID
        defer { if revision == generation { starting.remove(slotID); cancelledStarts.remove(startID) } }
        lastError = nil
        if cancelledStarts.contains(startID) {
            try await stateMachine.cancelPendingStart(slotID: slotID)
            await publish(); return
        }
        let thread: String
        if let existing = threadBySlot[slotID] {
            thread = existing
            try await stateMachine.bindThread(slotID: slotID, threadID: thread)
        } else {
            var params: [String: JSONValue] = ["model": .string(modelID), "approvalPolicy": .string("on-request"),
                                               "sandbox": .string(permission
                                                   .type == .safeRead ? "read-only" : "workspace-write")]
            if let cwd { params["cwd"] = .string(cwd) }
            let response = try await rpc.sendRequest(.threadStart, params: .object(params))
            try check(revision)
            guard let id = response.result?.objectValue?["thread"]?.objectValue?["id"]?.stringValue else {
                throw CodexSessionCoordinatorError.missingThreadID
            }
            thread = id
            threadBySlot[slotID] = id
            slotByThread[id] = slotID
            try await stateMachine.bindThread(slotID: slotID, threadID: id)
        }
        try check(revision)
        if cancelledStarts.contains(startID) {
            try await stateMachine.cancelPendingStart(slotID: slotID)
            await publish(); return
        }
        var sandbox: [String: JSONValue] =
            ["type": .string(permission.type == .safeRead ? "readOnly" : "workspaceWrite")]
        if permission.type == .workspaceWrite {
            sandbox["writableRoots"] = .array((permission.writableRoots ?? []).map(JSONValue.string))
            sandbox["networkAccess"] = .bool(permission.networkAccess)
        }
        var params: [String: JSONValue] = ["threadId": .string(thread), "model": .string(modelID),
                                           "approvalPolicy": .string("on-request"), "sandboxPolicy": .object(sandbox),
                                           "input": .array([.object([
                                               "type": .string("text"),
                                               "text": .string(userPrompt)
                                           ])])]
        if let cwd { params["cwd"] = .string(cwd) }
        if let effortID { params["effort"] = .string(effortID) }
        let response = try await rpc.sendRequest(.turnStart, params: .object(params),
                                                 timeout: timeoutMs.map { .milliseconds($0) })
        try check(revision)
        guard let turn = response.result?.objectValue?["turn"]?.objectValue?["id"]?.stringValue else {
            throw CodexSessionCoordinatorError.missingTurnID
        }
        // A turn/started notification can precede its response. State-machine start is idempotent.
        if let state = await stateMachine.snapshot(slotID: slotID),
           ![.completed, .interrupted, .failed, .running, .awaitingApproval].contains(state.phase)
        {
            try await stateMachine.onTurnStart(slotID: slotID, threadID: thread, turnID: turn)
        }
        if cancelledStarts.contains(startID) { _ = try await interruptActiveTurn(slotID: slotID) }
        await publish()
    }

    public func requestInterrupt(slotID: AgentSlotID, startID: UUID?) async throws -> Bool {
        guard connectionPhase == .ready else { throw CodexSessionCoordinatorError.invalidState("connection not ready") }
        if let startID, startIDs[slotID] != startID || starting.contains(slotID) {
            cancelledStarts.insert(startID)
            return true
        }
        return try await interruptActiveTurn(slotID: slotID)
    }

    public func interruptTurn(slotID: AgentSlotID) async throws {
        if starting.contains(slotID), let id = startIDs[slotID] { cancelledStarts.insert(id); return }
        _ = try await interruptActiveTurn(slotID: slotID)
    }

    private func interruptActiveTurn(slotID: AgentSlotID) async throws -> Bool {
        let revision = generation
        guard let state = await stateMachine.snapshot(slotID: slotID), let thread = state.threadID,
              let turn = state.turnID,
              state.phase == .running || state.phase == .awaitingApproval else { return false }
        guard interrupting.insert(slotID).inserted else { return true }
        defer { if generation == revision { interrupting.remove(slotID) } }
        _ = try await rpc.sendRequest(
            .turnInterrupt,
            params: .object(["threadId": .string(thread), "turnId": .string(turn)])
        )
        try check(revision)
        try await stateMachine.onInterrupt(slotID: slotID)
        approvals = approvals.filter { $0.value.slotID != slotID }
        lastError = nil
        await publish()
        return true
    }

    public func onServerEnvelope(_ envelope: CodexEnvelope) async { await receive(envelope, generation: generation) }
    private func receive(_ envelope: CodexEnvelope, generation revision: Int) async {
        guard revision == generation, connectionPhase != .stopped, connectionPhase != .failed else { return }
        do {
            guard let event = try envelope.asServerEvent() else { return }
            switch event {
            case .turnStarted, .turnCompleted, .turnFailed, .turnInterrupted:
                try await stateMachine.handle(event: event)
                let states = await stateMachine.allStates()
                approvals = approvals
                    .filter { [.running, .awaitingApproval].contains(states[$0.value.slotID]?.phase ?? .idle) }
            case let .commandExecutionRequestApproval(_, turn, thread, command),
                 let .fileChangeRequestApproval(_, turn, thread, command):
                guard let slot = slotByThread[thread], let original = envelope.id else {
                    if let id = envelope.id { try await rpc.sendEnvelope(CodexEnvelope(
                        id: id,
                        error: .init(code: -32602, message: "Unknown thread")
                    )) }
                    return
                }
                guard seenApprovalIDs.insert(original).inserted else { return }
                try await stateMachine.handle(event: event)
                let kind: CodexServerRequestKind = envelope.method == CodexMethod.commandExecutionRequestApproval
                    .rawValue
                    ? .commandExecutionRequestApproval : .fileChangeRequestApproval
                await approvalGate.registerRequest(approvalKey(original), kind: kind, for: slot, visibleSlotID: slot,
                                                   visibleWindowSeconds: approvalWindow)
                if approvals[original] == nil { approvals[original] = .init(
                    id: original,
                    slotID: slot,
                    detail: [command, envelope.params?.objectValue?["cwd"]?.stringValue,
                             envelope.params?.objectValue?["grantRoot"]?.stringValue,
                             envelope.params?.objectValue?["reason"]?.stringValue,
                             envelope.params?.objectValue?["itemId"]?.stringValue].compactMap { $0 }.joined(
                        separator: "\n"
                    ), threadID: thread, turnID: turn
                ) }
            case .serverRequest, .notification:
                // Unknown server requests require an explicit rejection; unknown notifications are forward compatible.
                if let id = envelope.id { try await rpc.sendEnvelope(CodexEnvelope(
                    id: id,
                    error: .init(code: -32601, message: "Unsupported request")
                )) }
            }
            await publish()
        } catch {
            lastError = error.localizedDescription
            await publish()
        }
    }

    private func approvalKey(_ id: CodexRequestID) -> String {
        switch id { case let .number(value): "number:\(value)"; case let .string(value): "string:\(value)" }
    }

    /// Compatibility entry point: ambiguous numeric/string IDs are never resolved by guessing.
    public func sendApproval(requestID: String, slotID: AgentSlotID, visibleSlotID: AgentSlotID,
                             decision: CodexApprovalDecision) async throws
    {
        let matches = approvals.values.filter { $0.id.stringValue == requestID }
        guard matches.count == 1,
              let request = matches.first else { throw CodexApprovalGateError.requestMissing(requestID) }
        try await sendApproval(id: request.id, slotID: slotID, visibleSlotID: visibleSlotID, decision: decision)
    }

    public func sendApproval(id: CodexRequestID, slotID: AgentSlotID, visibleSlotID: AgentSlotID,
                             decision: CodexApprovalDecision) async throws
    {
        guard connectionPhase == .ready, let pending = approvals[id] else {
            throw CodexApprovalGateError.requestMissing(id.stringValue)
        }
        guard responding.insert(id).inserted
        else { throw CodexSessionCoordinatorError.invalidState("approval response in flight") }
        let revision = generation
        defer { if revision == generation { responding.remove(id) } }
        let key = approvalKey(id)
        var effectiveDecision = decision
        do {
            let shouldSend: Bool
            do {
                shouldSend = try await approvalGate.prepare(requestID: key, by: slotID,
                                                            visibleSlotID: visibleSlotID, decision: decision)
            } catch CodexApprovalGateError.requestExpired {
                effectiveDecision = .decline
                shouldSend = try await approvalGate.prepare(requestID: key, by: slotID,
                                                            visibleSlotID: visibleSlotID, decision: .decline)
            }
            guard shouldSend else { return }
            try check(revision)
            try Task.checkCancellation()
            try await rpc.sendEnvelope(CodexEnvelope(id: id,
                                                     result: .object(
                                                         ["decision": .string(effectiveDecision == .approve ?
                                                                 "accept" : "decline")]
                                                     )))
            try check(revision)
            try await approvalGate.commit(
                requestID: key,
                by: slotID,
                visibleSlotID: visibleSlotID,
                decision: effectiveDecision
            )
            try check(revision)
            approvals.removeValue(forKey: id)
            let waiting = approvals.values
                .contains { $0.slotID == slotID && $0.threadID == pending.threadID && $0.turnID == pending.turnID }
            await stateMachine.updateApprovalWait(
                slotID: slotID,
                threadID: pending.threadID,
                turnID: pending.turnID,
                waiting: waiting
            )
            lastError = effectiveDecision != decision ? L10n.text("审批已过期，已向 Codex 拒绝该请求") : nil
            await publish()
        } catch {
            if revision == generation,
               connectionPhase == .ready { lastError = error.localizedDescription; await publish() }
            throw error
        }
    }
}
