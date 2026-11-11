import Foundation

public struct ParameterID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: ParameterID, rhs: ParameterID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
