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
            "未找到待处理审批 request-id=\(id)"
        case let .requestExpired(id):
            "审批 request-id=\(id) 已超时关闭"
        case let .slotMismatch(expected, actual):
            "审批 slot-id 不匹配（期望 \(expected.rawValue) 实际 \(actual.rawValue)）"
        case .visibilityMismatch:
            "审批按钮当前不可见，拒绝处理"
        case let .requestReplayed(id):
            "审批 request-id=\(id) 已被重复处理"
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
    private var pendingRequests: [String: CodexApprovalRequestRecord] = [:]
    private var resolvedRequests: [String: CodexApprovalDecision] = [:]

    public func registerRequest(
        _ requestID: String,
        kind: CodexServerRequestKind,
        for slotID: AgentSlotID,
        visibleSlotID: AgentSlotID,
        requestedAt: Date = .now,
        visibleWindowSeconds: TimeInterval = 8
    ) {
        let expiresAt = requestedAt.addingTimeInterval(visibleWindowSeconds)
        pendingRequests[requestID] = CodexApprovalRequestRecord(
            requestID: requestID,
            requestKind: kind,
            slotID: slotID,
            visibleSlotID: visibleSlotID,
            requestedAt: requestedAt,
            expiresAt: expiresAt
        )
    }

    public func resolve(
        requestID: String,
        by slotID: AgentSlotID,
        visibleSlotID: AgentSlotID,
        at: Date = .now,
        decision: CodexApprovalDecision
    ) throws -> CodexApprovalDecision {
        if let previous = resolvedRequests[requestID] {
            return previous
        }

        guard let request = pendingRequests.removeValue(forKey: requestID) else {
            throw CodexApprovalGateError.requestMissing(requestID)
        }

        if at > request.expiresAt {
            throw CodexApprovalGateError.requestExpired(requestID)
        }
        guard request.slotID == slotID else {
            pendingRequests[requestID] = request
            throw CodexApprovalGateError.slotMismatch(expected: request.slotID, actual: slotID)
        }
        guard request.visibleSlotID == visibleSlotID else {
            pendingRequests[requestID] = request
            throw CodexApprovalGateError.visibilityMismatch
        }

        resolvedRequests[requestID] = decision
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
        if let previous = resolvedRequests[requestID] {
            if previous != decision {
                throw CodexApprovalGateError.requestReplayed(requestID)
            }
            return false
        }

        _ = try resolve(
            requestID: requestID,
            by: slotID,
            visibleSlotID: visibleSlotID,
            at: at,
            decision: decision
        )
        return true
    }
}
