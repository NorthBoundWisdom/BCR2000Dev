import BCRFoundation
import BCRAgentDomain
import Foundation

public enum CodexApprovalGateError: Error, LocalizedError, Sendable {
    case requestMissing(String)
    case requestExpired(String)
    case slotMismatch(expected: AgentSlotID, actual: AgentSlotID)
    case visibilityMismatch
    case requestReplayed(String)

    public var errorDescription: String? {
        switch self {
        case let .requestMissing(id):
            L10n.text("未找到待处理审批 request-id=\(id)")
        case let .requestExpired(id):
            L10n.text("审批 request-id=\(id) 已超时关闭")
        case let .slotMismatch(expected, actual):
            L10n.text("审批 slot-id 不匹配（期望 \(expected.rawValue) 实际 \(actual.rawValue)）")
        case .visibilityMismatch:
            L10n.text("审批按钮当前不可见，拒绝处理")
        case let .requestReplayed(id):
            L10n.text("审批 request-id=\(id) 已被重复处理")
        }
    }
}

public struct CodexApprovalRequestRecord: Sendable {
    public let requestID: String
    public let requestKind: CodexServerRequestKind
    public let slotID: AgentSlotID
    public let visibleSlotID: AgentSlotID
    public let requestedAt: Date
    public let expiresAt: Date

    public init(
        requestID: String,
        requestKind: CodexServerRequestKind,
        slotID: AgentSlotID,
        visibleSlotID: AgentSlotID,
        requestedAt: Date,
        expiresAt: Date
    ) {
        self.requestID = requestID
        self.requestKind = requestKind
        self.slotID = slotID
        self.visibleSlotID = visibleSlotID
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

public actor CodexApprovalGate {
    private var seenRequests: Set<String> = []
    private var pendingRequests: [String: CodexApprovalRequestRecord] = [:]
    private var resolvedRequests: [String: (record: CodexApprovalRequestRecord, decision: CodexApprovalDecision)] = [:]

    public func registerRequest(
        _ requestID: String,
        kind: CodexServerRequestKind,
        for slotID: AgentSlotID,
        visibleSlotID: AgentSlotID,
        requestedAt: Date = .now,
        visibleWindowSeconds: TimeInterval? = nil
    ) {
        guard seenRequests.insert(requestID).inserted else { return }
        let expiresAt = visibleWindowSeconds
            .map { requestedAt.addingTimeInterval($0.isFinite ? max(0, $0) : 0) } ?? .distantFuture
        pendingRequests[requestID] = CodexApprovalRequestRecord(
            requestID: requestID,
            requestKind: kind,
            slotID: slotID,
            visibleSlotID: visibleSlotID,
            requestedAt: requestedAt,
            expiresAt: expiresAt
        )
    }

    /// Validate intent without consuming it. The caller must commit only after transport delivery.
    public func prepare(
        requestID: String, by slotID: AgentSlotID, visibleSlotID: AgentSlotID,
        at: Date = .now, decision: CodexApprovalDecision
    ) throws -> Bool {
        if let previous = resolvedRequests[requestID] {
            try validateOwner(previous.record, slotID: slotID, visibleSlotID: visibleSlotID)
            guard previous.decision == decision else { throw CodexApprovalGateError.requestReplayed(requestID) }
            return false
        }
        guard let request = pendingRequests[requestID] else { throw CodexApprovalGateError.requestMissing(requestID) }
        try validateOwner(request, slotID: slotID, visibleSlotID: visibleSlotID)
        // A denial must remain reachable even after an explicit approval deadline.
        if decision == .approve, at > request.expiresAt { throw CodexApprovalGateError.requestExpired(requestID) }
        return true
    }

    public func commit(
        requestID: String, by slotID: AgentSlotID, visibleSlotID: AgentSlotID,
        decision: CodexApprovalDecision
    ) throws {
        if let previous = resolvedRequests[requestID] {
            try validateOwner(previous.record, slotID: slotID, visibleSlotID: visibleSlotID)
            guard previous.decision == decision else { throw CodexApprovalGateError.requestReplayed(requestID) }
            return
        }
        guard let record = pendingRequests[requestID] else { throw CodexApprovalGateError.requestMissing(requestID) }
        try validateOwner(record, slotID: slotID, visibleSlotID: visibleSlotID)
        pendingRequests[requestID] = nil
        resolvedRequests[requestID] = (record, decision)
    }

    private func validateOwner(
        _ record: CodexApprovalRequestRecord,
        slotID: AgentSlotID,
        visibleSlotID: AgentSlotID
    ) throws {
        guard record.slotID == slotID else { throw CodexApprovalGateError.slotMismatch(
            expected: record.slotID,
            actual: slotID
        ) }
        guard record.visibleSlotID == visibleSlotID else { throw CodexApprovalGateError.visibilityMismatch }
    }

    public func resolve(
        requestID: String, by slotID: AgentSlotID, visibleSlotID: AgentSlotID,
        at: Date = .now, decision: CodexApprovalDecision
    ) throws -> CodexApprovalDecision {
        _ = try resolveAgain(requestID: requestID, by: slotID, visibleSlotID: visibleSlotID, at: at, decision: decision)
        return decision
    }

    public func clearExpiredRequests(now: Date = .now) {
        let expired = pendingRequests.filter { _, value in
            value.expiresAt < now
        }
        for (requestID, _) in expired {
            pendingRequests.removeValue(forKey: requestID)
        }
    }

    public func clearAll() {
        seenRequests.removeAll(keepingCapacity: true)
        pendingRequests.removeAll(keepingCapacity: true)
        resolvedRequests.removeAll(keepingCapacity: true)
    }

    public func pendingRequestCount() -> Int {
        pendingRequests.count
    }

    public func resolveAgain(
        requestID: String,
        by slotID: AgentSlotID,
        visibleSlotID: AgentSlotID,
        at: Date = .now,
        decision: CodexApprovalDecision
    ) throws -> Bool {
        let shouldCommit = try prepare(
            requestID: requestID,
            by: slotID,
            visibleSlotID: visibleSlotID,
            at: at,
            decision: decision
        )
        guard shouldCommit else { return false }
        try commit(requestID: requestID, by: slotID, visibleSlotID: visibleSlotID, decision: decision)
        return true
    }
}
