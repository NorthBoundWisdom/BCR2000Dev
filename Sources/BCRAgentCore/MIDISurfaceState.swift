import Foundation

public enum MIDIObservationDirection: String, Equatable, Sendable {
    case input
    case output
}

public struct MIDIControlSnapshot: Identifiable, Equatable, Sendable {
    public let id: MIDIControlID
    public private(set) var inputValue: UInt8?
    public private(set) var outputValue: UInt8?
    public private(set) var lastDirection: MIDIObservationDirection
    public private(set) var eventCount: Int
    public private(set) var lastUpdated: Date

    public var displayedValue: UInt8 {
        switch lastDirection {
        case .input:
            inputValue ?? outputValue ?? 0
        case .output:
            outputValue ?? inputValue ?? 0
        }
    }

    public var normalizedValue: Double {
        Double(displayedValue) / 127
    }

    init(
        id: MIDIControlID,
        value: UInt8,
        direction: MIDIObservationDirection,
        observedAt: Date
    ) {
        self.id = id
        inputValue = direction == .input ? value : nil
        outputValue = direction == .output ? value : nil
        lastDirection = direction
        eventCount = 1
        lastUpdated = observedAt
    }

    mutating func observe(
        value: UInt8,
        direction: MIDIObservationDirection,
        at observedAt: Date
    ) {
        switch direction {
        case .input:
            inputValue = value
        case .output:
            outputValue = value
        }
        lastDirection = direction
        eventCount += 1
        lastUpdated = observedAt
    }
}

public struct MIDISurfaceState: Sendable {
    private var snapshots: [MIDIControlID: MIDIControlSnapshot] = [:]
    private var discoveryOrder: [MIDIControlID] = []

    public init() {}

    public var controls: [MIDIControlSnapshot] {
        discoveryOrder.compactMap { snapshots[$0] }
    }

    @discardableResult
    public mutating func observe(
        _ message: MIDIVoiceMessage,
        direction: MIDIObservationDirection,
        at observedAt: Date = .now
    ) -> MIDIControlSnapshot {
        let control = message.controlID
        let value: UInt8
        switch message {
        case .noteOff:
            value = 0
        case .controlChange, .noteOn:
            value = message.value
        }

        if var snapshot = snapshots[control] {
            snapshot.observe(value: value, direction: direction, at: observedAt)
            snapshots[control] = snapshot
            return snapshot
        }

        let snapshot = MIDIControlSnapshot(
            id: control,
            value: value,
            direction: direction,
            observedAt: observedAt
        )
        snapshots[control] = snapshot
        discoveryOrder.append(control)
        return snapshot
    }

    public mutating func reset() {
        snapshots.removeAll()
        discoveryOrder.removeAll()
    }
}
