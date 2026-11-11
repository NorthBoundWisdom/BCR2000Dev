import Foundation

/// Immutable update batches shared by UI and authenticated transports.
public struct ParameterChangeBatch: Equatable, Sendable {
    public let revision: UInt64
    public let values: [String: Double]
    public let removed: [String]
    public let reset: Bool

    public var jsonValue: JSONValue {
        .object(["revision": .string(String(revision)),
                 "values": .object(values.mapValues(JSONValue.double)),
                 "removed": .array(removed.map(JSONValue.string)), "reset": .bool(reset)])
    }
}
