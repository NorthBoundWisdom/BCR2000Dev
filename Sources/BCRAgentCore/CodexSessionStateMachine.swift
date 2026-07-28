import Foundation

public enum CodexSessionStateMachineError: Error, LocalizedError, Sendable {
    case slotMissing(AgentSlotID)
    case threadMissing(String)
    case invalidTransition(slot: AgentSlotID, from: CodexTurnPhase, to: CodexTurnPhase)
    case unexpectedEvent

    public var errorDescription: String? {
        switch self {
        case let .slotMissing(slotID):
            "缺失槽位状态：\(slotID.rawValue)"
        case let .threadMissing(threadID):
            "缺失 thread-id：\(threadID)"
        case let .invalidTransition(slot, from, to):
            "槽位 \(slot.rawValue) 不允许从 \(from.rawValue) 转 \(to.rawValue)"
        case .unexpectedEvent:
            "收到无法处理的事件"
        }
    }
}

public enum CodexTurnPhase: String, Codable, Sendable {
    case idle
    case threadStarting
    case activeThread
    case turnStarting
    case running
    case awaitingApproval
    case completed
    case interrupted
    case failed
}

public struct CodexSlotRuntimeState: Codable, Equatable, Sendable {
    public var phase: CodexTurnPhase
    public var threadID: String?
    public var turnID: String?
    public var lastError: String?
    public var lastEventAt: Date

    public init(
        phase: CodexTurnPhase = .idle,
        threadID: String? = nil,
        turnID: String? = nil,
        lastError: String? = nil,
        lastEventAt: Date = .now
    ) {
        self.phase = phase
        self.threadID = threadID
        self.turnID = turnID
        self.lastError = lastError
        self.lastEventAt = lastEventAt
    }
}

public actor CodexSessionStateMachine {
    private var slots: [AgentSlotID: CodexSlotRuntimeState]

    public init(slotIDs: [AgentSlotID] = (1...8).map { AgentSlotID($0) }) {
        slots = Dictionary(
            uniqueKeysWithValues: slotIDs.map { slotID in
                (slotID, CodexSlotRuntimeState())
            }
        )
    }

    public func snapshot(slotID: AgentSlotID) -> CodexSlotRuntimeState? {
        slots[slotID]
    }

    public func allStates() -> [AgentSlotID: CodexSlotRuntimeState] {
        slots
    }

    public func onThreadStart(slotID: AgentSlotID, threadID: String, at: Date = .now) throws {
        guard var state = slots[slotID] else {
            throw CodexSessionStateMachineError.slotMissing(slotID)
        }
        guard state.phase == .idle || state.phase == .completed || state.phase == .interrupted || state.phase == .failed else {
            throw CodexSessionStateMachineError.invalidTransition(
                slot: slotID,
                from: state.phase,
                to: .activeThread
            )
        }

        state.phase = .activeThread
        state.threadID = threadID
        state.lastError = nil
        state.lastEventAt = at
        slots[slotID] = state
    }

    public func onTurnStart(slotID: AgentSlotID, threadID: String, turnID: String, at: Date = .now) throws {
        guard var state = slots[slotID] else {
            throw CodexSessionStateMachineError.slotMissing(slotID)
        }
        guard state.phase == .activeThread || state.phase == .turnStarting || state.phase == .idle else {
            throw CodexSessionStateMachineError.invalidTransition(
                slot: slotID,
                from: state.phase,
                to: .running
            )
        }
        guard state.threadID == threadID else {
            throw CodexSessionStateMachineError.threadMissing(threadID)
        }

        state.phase = .running
        state.turnID = turnID
        state.lastError = nil
        state.lastEventAt = at
        slots[slotID] = state
    }

    public func onApprovalRequired(
        slotID: AgentSlotID,
        threadID: String,
        turnID: String,
        at: Date = .now
    ) throws {
        guard var state = slots[slotID] else {
            throw CodexSessionStateMachineError.slotMissing(slotID)
        }
        guard state.threadID == threadID else {
            throw CodexSessionStateMachineError.threadMissing(threadID)
        }
        guard state.turnID == turnID else {
            throw CodexSessionStateMachineError.unexpectedEvent
        }
        guard state.phase == .running else {
            throw CodexSessionStateMachineError.invalidTransition(
                slot: slotID,
                from: state.phase,
                to: .awaitingApproval
            )
        }

        state.phase = .awaitingApproval
        state.lastEventAt = at
        slots[slotID] = state
    }

    public func onTurnCompleted(
        threadID: String,
        turnID: String,
        at: Date = .now
    ) throws {
        guard let slotID = findSlotID(for: threadID) else {
            throw CodexSessionStateMachineError.threadMissing(threadID)
        }
        guard var state = slots[slotID] else {
            throw CodexSessionStateMachineError.slotMissing(slotID)
        }

        if let existingTurnID = state.turnID, existingTurnID != turnID {
            return
        }

        state.phase = .completed
        state.turnID = nil
        state.lastEventAt = at
        slots[slotID] = state
    }

    public func onInterrupt(slotID: AgentSlotID, at: Date = .now) throws {
        guard var state = slots[slotID] else {
            throw CodexSessionStateMachineError.slotMissing(slotID)
        }

        switch state.phase {
        case .running, .awaitingApproval, .turnStarting:
            state.phase = .interrupted
            state.turnID = nil
            state.lastEventAt = at
            state.lastError = nil
            slots[slotID] = state
        default:
            break
        }
    }

    public func handle(event: CodexServerEvent) throws {
        switch event {
        case let .turnStarted(threadID: threadID, turnID: turnID):
            guard let slotID = findSlotID(for: threadID) else {
                throw CodexSessionStateMachineError.threadMissing(threadID)
            }
            try onTurnStart(slotID: slotID, threadID: threadID, turnID: turnID)

        case let .turnCompleted(threadID: threadID, turnID: turnID):
            try onTurnCompleted(threadID: threadID, turnID: turnID)

        case let .commandExecutionRequestApproval(requestID: _, turnID: turnID, threadID: threadID, command: _):
            guard let slotID = findSlotID(for: threadID) else {
                throw CodexSessionStateMachineError.threadMissing(threadID)
            }
            try onApprovalRequired(slotID: slotID, threadID: threadID, turnID: turnID)

        case let .fileChangeRequestApproval(requestID: _, turnID: turnID, threadID: threadID, path: _):
            guard let slotID = findSlotID(for: threadID) else {
                throw CodexSessionStateMachineError.threadMissing(threadID)
            }
            try onApprovalRequired(slotID: slotID, threadID: threadID, turnID: turnID)

        case .serverRequest, .notification:
            throw CodexSessionStateMachineError.unexpectedEvent
        }
    }

    public func bindThread(slotID: AgentSlotID, threadID: String, at: Date = .now) throws {
        try onThreadStart(slotID: slotID, threadID: threadID, at: at)
    }

    public func reset(slotID: AgentSlotID) throws {
        guard slots.keys.contains(slotID) else {
            throw CodexSessionStateMachineError.slotMissing(slotID)
        }
        slots[slotID] = CodexSlotRuntimeState()
    }

    private func findSlotID(for threadID: String) -> AgentSlotID? {
        slots.first(where: { $0.value.threadID == threadID })?.key
    }
}
