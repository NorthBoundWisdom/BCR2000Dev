import BCRFoundation
import Foundation

public struct ControlInputReview: Equatable, Sendable {
    public private(set) var eventCount = 0
    public private(set) var minimum: UInt16?
    public private(set) var maximum: UInt16?
    public private(set) var latestValue: UInt16?
    public private(set) var lastIdentity: MIDIControlID?
    public private(set) var addresses: Set<MIDIControlID> = []
    public private(set) var lastReceived: Date?
    public private(set) var lastMonotonicTime: Double?
    public init() {}

    mutating func record(_ message: MIDIVoiceMessage, event: MonitorEvent) {
        eventCount += 1
        minimum = min(minimum ?? message.dataValue, message.dataValue)
        maximum = max(maximum ?? message.dataValue, message.dataValue)
        latestValue = message.dataValue
        lastIdentity = message.controlID; addresses.insert(message.controlID)
        lastReceived = event.time; lastMonotonicTime = event.monotonicTime
    }

    public func matches(_ identity: MIDIControlID?) -> Bool? {
        guard let lastIdentity else { return nil }
        return identity == lastIdentity
    }
}

/// Passive observations only. No effects, bindings, learning or hardware APIs are reachable.
public struct InputCoverage: Sendable {
    public private(set) var messageCount = 0
    public private(set) var unmappedMessageCount = 0
    public private(set) var echoCount = 0
    public private(set) var reviews: [BCRControlID: ControlInputReview] = [:]
    private var nrpn = NRPNAssembler()
    private var lastMap: HardwareMap?
    public init() {}
    public var observedControlCount: Int { reviews.count }
    public func review(_ control: BCRControlID) -> ControlInputReview { reviews[control] ?? .init() }

    public mutating func observe(_ event: MonitorEvent, feedbackEcho: Bool, map: HardwareMap) {
        guard event.direction == .input else { return }
        if lastMap != map { nrpn.reset(); lastMap = map }
        messageCount += 1
        guard !feedbackEcho else { echoCount += 1; return }
        var message = event.message
        if case let .controlChange(channel, number, _) = message,
           map.entries.contains(where: { $0.midi.kind == .nrpn && $0.midi.channel == channel }),
           [6, 38, 98, 99, 100, 101, 121].contains(number)
        {
            guard let assembled = nrpn.consume(message, at: Date(timeIntervalSinceReferenceDate: event.monotonicTime))
            else { return }
            message = assembled
        }
        guard let control = map.control(for: message.controlID) else { unmappedMessageCount += 1; return }
        var review = reviews[control] ?? .init()
        review.record(message, event: event); reviews[control] = review
    }
}
