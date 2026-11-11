import Foundation

/// Legacy surface action identity; contains no Agent state or backend behavior.
public struct AgentSlotID: Hashable, Codable, Sendable, Identifiable, Comparable {
    public let rawValue: Int

    public var id: Int { rawValue }

    public init(_ rawValue: Int) {
        precondition((1 ... 8).contains(rawValue), "Agent slot must be in 1...8")
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
