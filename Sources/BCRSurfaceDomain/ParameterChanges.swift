import BCRFoundation
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

/// Merge one frame of updates while preserving removal/reset semantics.
public struct ParameterChangeAccumulator: Sendable {
    private var revision: UInt64 = 0
    private var values: [String: Double] = [:]
    private var removed: Set<String> = []
    private var reset = false
    private var hasBatch = false
    public init() {}
    public mutating func append(_ batch: ParameterChangeBatch) {
        if batch.reset { values = [:]; removed = []; reset = true }
        for id in batch.removed { values[id] = nil; removed.insert(id) }
        for (id, value) in batch.values { values[id] = value; removed.remove(id) }
        revision = batch.revision
        hasBatch = true
    }

    public mutating func take() -> ParameterChangeBatch? {
        guard hasBatch else { return nil }
        let result = ParameterChangeBatch(revision: revision, values: values, removed: removed.sorted(), reset: reset)
        self = ParameterChangeAccumulator()
        return result
    }
}
