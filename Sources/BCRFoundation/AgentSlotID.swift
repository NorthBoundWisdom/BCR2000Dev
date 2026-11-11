import Foundation

public enum AgentSlotIDError: Error, Equatable, LocalizedError, Sendable {
    case outOfRange(Int)
    public var errorDescription: String? { L10n.text("Agent 槽位必须为 1–8") }
}

/// Legacy disk/source identity only. New plugin APIs use checked, configurable integer indices.
public struct AgentSlotID: Hashable, Codable, Sendable, Identifiable, Comparable {
    public let rawValue: Int

    public var id: Int { rawValue }

    /// Unchecked source-compatible construction; invalid input is rejected at decoding,
    /// configuration validation, and the plugin adapter boundary instead of trapping.
    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(validating rawValue: Int) throws {
        guard (1 ... 8).contains(rawValue) else { throw AgentSlotIDError.outOfRange(rawValue) }
        self.rawValue = rawValue
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(Int.self, forKey: .rawValue)
        guard (1 ... 8).contains(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawValue,
                in: container,
                debugDescription: "Agent slot must be 1...8"
            )
        }
        self.init(raw)
    }

    public static func < (lhs: AgentSlotID, rhs: AgentSlotID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
