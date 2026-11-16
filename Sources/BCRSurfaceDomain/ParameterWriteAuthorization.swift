import BCRFoundation
import Foundation

/// Trusted host identity; wire callers cannot supply or promote this value.
public enum ParameterWriteIdentity: String, Hashable, Sendable { case local, remote, history }

/// Revocable permission snapshot. It contains no parameter values or credentials.
public struct ParameterWriteContext: Equatable, Sendable {
    public let source: DeviceSource
    public let generation: String
    public let mappingRevision: UInt64
    public let identities: Set<ParameterWriteIdentity>
    public let parameters: Set<ParameterID>?
    public let allowsWrite: Bool
    public let allowsDisplay: Bool
    public init(source: DeviceSource, generation: String, mappingRevision: UInt64,
                identities: Set<ParameterWriteIdentity> = [.local, .remote, .history],
                parameters: Set<ParameterID>? = nil, allowsWrite: Bool, allowsDisplay: Bool)
    {
        self.source = source; self.generation = generation; self.mappingRevision = mappingRevision
        self.identities = identities; self.parameters = parameters
        self.allowsWrite = allowsWrite; self.allowsDisplay = allowsDisplay
    }
}

public struct ParameterAuthorityRequest: Equatable, Sendable {
    public let parameter: ParameterID
    public let requestedValue: Double
    public let identity: ParameterWriteIdentity
    public let source: DeviceSource
    public let generation: String
    public let mappingRevision: UInt64
}

/// Only a trusted local authority supplies this reply. A rejected value is business
/// authority, never device-readback evidence, and never creates an input event.
public enum ParameterAuthorityDecision: Equatable, Sendable {
    case accept
    case reject(actual: Double, reason: String)
}

public enum ParameterWriteFailure: Error, LocalizedError, Equatable, Sendable {
    case denied, staleContext, invalidAuthority, authorityRejected(String)
    public var errorDescription: String? {
        switch self {
        case .denied: L10n.text("参数写入已被当前授权撤销")
        case .staleContext: L10n.text("参数写入上下文已失效")
        case .invalidAuthority: L10n.text("外部权威回复无效")
        case let .authorityRejected(reason): L10n.text("外部权威拒绝写入：\(reason)")
        }
    }
}
