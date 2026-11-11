import BCRFoundation
import Foundation

public enum JSONLinkEvent: Equatable, Sendable {
    case heartbeat(Date, peerReset: Bool)
    case samples([ParameterSample])
    case ignored
}

/// Host Date/session compatibility over the shared replay-resistant link.
public struct JSONParameterLink: Sendable {
    private var shared: SharedJSONParameterLink
    public var session: String { shared.session }
    public init(session: String = UUID().uuidString) { shared = .init(session: session) }
    public mutating func ping(at now: Date) -> JSONValue { shared.ping(at: now.timeIntervalSinceReferenceDate) }
    public mutating func command(_ frame: ParameterOutputFrame) throws
        -> JSONValue { try withLegacyOutputErrors { try shared.command(frame) } }
    public mutating func receive(_ value: JSONValue, at now: Date) throws -> JSONLinkEvent {
        let result = try withLegacyOutputErrors { try shared.receive(value, at: now.timeIntervalSinceReferenceDate) }
        switch result {
        case let .heartbeat(time, peerReset): return .heartbeat(
                Date(timeIntervalSinceReferenceDate: time),
                peerReset: peerReset
            )
        case let .samples(samples): return .samples(samples.map(ParameterSample.init(shared:)))
        case .ignored: return .ignored
        }
    }
}
