import Foundation

public enum JSONLinkEvent: Equatable, Sendable {
    case heartbeat(Date, peerReset: Bool)
    case samples([ParameterSample])
    case ignored
}

/// Transport-independent, replay-resistant parameter link used by WebSocket and ROS 2 rosbridge.
public struct JSONParameterLink: Sendable {
    public let session: String
    private var sequence: UInt64 = 0
    private var stateSequence: UInt64?
    private var pongSequence: UInt64?
    private var pending: [UInt64: Date] = [:]
    private var epoch: String?
    public init(session: String = UUID().uuidString) { self.session = session }
    public mutating func ping(at now: Date) -> JSONValue {
        pending = pending.filter { now.timeIntervalSince($0.value) <= 1 }
        sequence &+= 1
        pending[sequence] = now
        return .object(["type": .string("ping"), "session": .string(session), "sequence": .string(String(sequence))])
    }

    public mutating func command(_ frame: ParameterOutputFrame) throws -> JSONValue {
        guard let epoch else { throw MotionSafetyError(L10n.text("尚未确认对端标识")) }
        guard frame.enabled || frame.values.isEmpty else { throw MotionSafetyError(L10n.text("禁止在停止帧中发送运动值")) }
        guard frame.values.values.allSatisfy({ $0.isFinite }) else { throw MotionSafetyError(L10n.text("参数值必须是有限数值")) }
        sequence &+= 1
        return .object(["type": .string("command"), "session": .string(session), "epoch": .string(epoch),
                        "sequence": .string(String(sequence)), "enabled": .bool(frame.enabled),
                        "values": .object(Dictionary(uniqueKeysWithValues: frame.values.map { (
                            $0.key.rawValue,
                            .double($0.value)
                        ) }))])
    }

    public mutating func receive(_ value: JSONValue, at now: Date) throws -> JSONLinkEvent {
        guard let object = value.objectValue, object["session"] == .string(session),
              let raw = object["sequence"]?.stringValue, let sequence = UInt64(raw),
              let peer = object["epoch"]?.stringValue, !peer.isEmpty, peer.utf8.count <= 128 else { return .ignored }
        switch object["type"]?.stringValue {
        case "pong":
            guard let sent = pending.removeValue(forKey: sequence), now >= sent, now.timeIntervalSince(sent) <= 0.3,
                  pongSequence.map({ sequence > $0 }) ?? true else { return .ignored }
            let reset = epoch != nil && epoch != peer
            epoch = peer
            pongSequence = sequence
            if reset { stateSequence = nil }
            return .heartbeat(now, peerReset: reset)
        case "state":
            guard epoch == peer, stateSequence.map({ sequence > $0 }) ?? true else { return .ignored }
            guard let values = object["values"]?.objectValue, !values.isEmpty, values.count <= 1024 else {
                throw MotionSafetyError(L10n.text("实际回传包含未知参数或非法数值"))
            }
            var samples: [ParameterSample] = []
            for (id, value) in values {
                guard !id.isEmpty, id.utf8.count <= 1024, let number = value.finiteNumber else {
                    throw MotionSafetyError(L10n.text("实际回传包含未知参数或非法数值"))
                }
                samples.append(.init(id: ParameterID(id), value: number, receivedAt: now))
            }
            stateSequence = sequence
            return .samples(samples.sorted { $0.id < $1.id })
        default: return .ignored
        }
    }
}
