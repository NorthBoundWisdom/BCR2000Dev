import BCRFoundation
import Foundation

import enum AgentPlugin.AgentRunState
import struct AgentPlugin.AgentSlot

public extension AgentRunState {
    var displayName: String {
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
}

/// Host presentation only: shared state plus user-facing name, text and audit Date.
public struct AgentSlotPresentation: Identifiable, Equatable, Sendable {
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

    public static func mockSlots() -> [AgentSlotPresentation] {
        (1 ... 8).map {
            AgentSlotPresentation(id: AgentSlotID($0), name: "Agent \($0)")
        }
    }

    public init(core slot: AgentPlugin.AgentSlot, name: String, statusText: String, lastUpdated: Date) {
        self.init(id: AgentSlotID(slot.id), name: name, state: slot.state, progress: slot.progress,
                  statusText: statusText, lastUpdated: lastUpdated)
    }
}
