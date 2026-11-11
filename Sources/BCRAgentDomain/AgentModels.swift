import BCRFoundation
import Foundation

public enum AgentRunState: String, CaseIterable, Codable, Sendable {
    case idle
    case queued
    case running
    case waitingApproval
    case completed
    case interrupted
    case error

    public var isActive: Bool {
        switch self {
        case .queued, .running, .waitingApproval:
            true
        case .idle, .completed, .interrupted, .error:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .idle: L10n.text("空闲")
        case .queued: L10n.text("排队中")
        case .running: L10n.text("运行中")
        case .waitingApproval: L10n.text("等待批准")
        case .completed: L10n.text("已完成")
        case .interrupted: L10n.text("已中断")
        case .error: L10n.text("错误")
        }
    }

    /// A single 7-bit value that can drive either a BCR2000 button LED or encoder ring.
    public var feedbackValue: UInt8 {
        switch self {
        case .idle: 0
        case .queued: 40
        case .running: 127
        case .waitingApproval: 96
        case .completed: 72
        case .interrupted: 20
        case .error: 8
        }
    }
}

public struct AgentSlot: Identifiable, Equatable, Codable, Sendable {
    public let id: AgentSlotID
    public var name: String
    public var state: AgentRunState
    public var progress: Double
    public var statusText: String
    public var lastUpdated: Date

    public init(
        id: AgentSlotID,
        name: String,
        state: AgentRunState = .idle,
        progress: Double = 0,
        statusText: String = L10n.text("等待任务"),
        lastUpdated: Date = .now
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.progress = progress
        self.statusText = statusText
        self.lastUpdated = lastUpdated
    }

    public static func mockSlots() -> [AgentSlot] {
        (1 ... 8).map {
            AgentSlot(id: AgentSlotID($0), name: "Agent \($0)")
        }
    }
}

public enum AgentStateMachineError: Error, Equatable, LocalizedError, Sendable {
    case unknownSlot(AgentSlotID)
    case invalidTransition(slot: AgentSlotID, from: AgentRunState, to: AgentRunState)

    public var errorDescription: String? {
        switch self {
        case let .unknownSlot(slot):
            L10n.text("未知槽位 \(slot.rawValue)")
        case let .invalidTransition(slot, from, to):
            L10n.text("槽位 \(slot.rawValue) 不能从 \(from.rawValue) 转换到 \(to.rawValue)")
        }
    }
}

public struct AgentStateMachine: Sendable {
    public private(set) var slots: [AgentSlot]

    public init(slots: [AgentSlot] = AgentSlot.mockSlots()) {
        self.slots = slots.sorted { $0.id < $1.id }
    }

    @discardableResult
    public mutating func transition(
        _ slotID: AgentSlotID,
        to newState: AgentRunState,
        progress: Double? = nil,
        statusText: String? = nil,
        now: Date = .now
    ) throws -> AgentSlot {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else {
            throw AgentStateMachineError.unknownSlot(slotID)
        }

        let oldState = slots[index].state
        guard Self.allows(from: oldState, to: newState) else {
            throw AgentStateMachineError.invalidTransition(
                slot: slotID,
                from: oldState,
                to: newState
            )
        }

        slots[index].state = newState
        if let progress {
            slots[index].progress = min(max(progress, 0), 1)
        }
        if let statusText {
            slots[index].statusText = statusText
        }
        slots[index].lastUpdated = now
        return slots[index]
    }

    @discardableResult
    public mutating func updateProgress(
        _ slotID: AgentSlotID,
        progress: Double,
        statusText: String,
        now: Date = .now
    ) throws -> AgentSlot {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else {
            throw AgentStateMachineError.unknownSlot(slotID)
        }
        guard slots[index].state == .running else {
            throw AgentStateMachineError.invalidTransition(
                slot: slotID,
                from: slots[index].state,
                to: .running
            )
        }

        slots[index].progress = min(max(progress, 0), 1)
        slots[index].statusText = statusText
        slots[index].lastUpdated = now
        return slots[index]
    }

    public func slot(_ slotID: AgentSlotID) -> AgentSlot? {
        slots.first { $0.id == slotID }
    }

    public static func allows(from oldState: AgentRunState, to newState: AgentRunState) -> Bool {
        if oldState == newState {
            return true
        }
        if newState == .error {
            return true
        }

        return switch (oldState, newState) {
        case (.idle, .queued),
             (.completed, .queued),
             (.interrupted, .queued),
             (.error, .queued),
             (.queued, .running),
             (.queued, .interrupted),
             (.running, .waitingApproval),
             (.running, .completed),
             (.running, .interrupted),
             (.waitingApproval, .running),
             (.waitingApproval, .interrupted):
            true
        default:
            false
        }
    }
}
