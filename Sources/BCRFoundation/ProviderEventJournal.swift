import Foundation

/// Bounded per-resource observations. No domain has access to another journal's mutation.
@MainActor
public final class ProviderEventJournal {
    public private(set) var generation = UUID().uuidString
    public private(set) var sequence = 0
    public private(set) var dropped = 0
    public private(set) var source: ProviderSource
    private let capacity: Int
    private var events: [JSONValue] = []
    private var observers: [UUID: @MainActor (JSONValue) -> Void] = [:]
    var observerCount: Int { observers.count }
    private let monotonic: @MainActor () -> Double
    private let utc: @MainActor () -> Date

    public init(source: ProviderSource, capacity: Int = 512,
                monotonic: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
                utc: @escaping @MainActor () -> Date = { .now })
    {
        self.source = source; self.capacity = max(1, capacity); self.monotonic = monotonic; self.utc = utc
    }

    public func reset(source: ProviderSource) {
        self.source = source; generation = UUID().uuidString; sequence = 0; dropped = 0; events.removeAll()
        let value = self.snapshot()
        for observer in Array(observers.values) { observer(value) }
    }

    public func append(kind: String, payload: JSONValue, source: ProviderSource? = nil) {
        sequence += 1
        let event: JSONValue = .object([
            "schema_version": .number(1), "generation": .string(generation), "sequence": .number(sequence),
            "source": .string((source ?? self.source).rawValue), "kind": .string(kind),
            "observed_monotonic_s": .double(monotonic()),
            "observed_at": .string(ISO8601DateFormatter().string(from: utc())), "payload": payload
        ])
        events.append(event)
        if events.count > capacity { events.removeFirst(events.count - capacity); dropped += 1 }
        let delta = envelope(events: [event], reset: false)
        for observer in Array(observers.values) { observer(delta) }
    }

    public func snapshot() -> JSONValue { envelope(events: events, reset: true) }
    public func read(generation expected: String?, after: Int = 0, limit: Int = 256) throws -> JSONValue {
        try ProviderValidation.require(
            after >= 0 && (1 ... 256).contains(limit),
            "invalid_argument",
            "Invalid event cursor or limit"
        )
        if let expected { try ProviderValidation.require(
            expected == generation,
            "stale_generation",
            "The event generation changed"
        ) } else {
            try ProviderValidation.require(
                after == 0,
                "invalid_argument",
                "A generation is required to resume an event cursor"
            )
            return envelope(events: Array(events.suffix(limit)), reset: true)
        }
        let earliest = events.first?.objectValue?["sequence"]?.roundedIntValue ?? sequence + 1
        try ProviderValidation.require(
            after >= earliest - 1,
            "event_gap",
            "The event cursor is older than the bounded inventory"
        )
        try ProviderValidation.require(
            after <= sequence,
            "invalid_argument",
            "The event cursor is ahead of the inventory"
        )
        return envelope(
            events: Array(events.filter { ($0.objectValue?["sequence"]?.roundedIntValue ?? 0) > after }.prefix(limit)),
            reset: expected == nil
        )
    }

    public func observe(_ callback: @escaping @MainActor (JSONValue) -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }
    private func envelope(events: [JSONValue], reset: Bool) -> JSONValue {
        .object(["schema_version": .number(1), "generation": .string(generation), "source": .string(source.rawValue),
                 "earliest_sequence": .number(self.events.first?.objectValue?["sequence"]?
                     .roundedIntValue ?? sequence + 1),
                 "latest_sequence": .number(sequence), "dropped": .number(dropped), "reset": .bool(reset),
                 "events": .array(events)])
    }
}
