import BCRAgentCore
import Foundation

enum OutputTransportKind: String, Codable, CaseIterable { case osc, webSocket, rosbridge }

@MainActor
final class OutputTransportRouter: OutputTransport {
    var onSamples: (@MainActor ([ParameterSample]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var isConnected: Bool { active.isConnected }
    private var active: any OutputTransport
    private var kind: OutputTransportKind = .osc
    init() { active = OSCParameterAdapter(); attach() }
    func select(_ kind: OutputTransportKind) {
        guard self.kind != kind else { return }
        active.stop()
        self.kind = kind
        switch kind {
        case .osc: active = OSCParameterAdapter()
        case .webSocket: active = WebSocketParameterAdapter()
        case .rosbridge: active = WebSocketParameterAdapter(rosbridge: true)
        }
        attach()
    }

    private func attach() {
        active.onSamples = { [weak self] in self?.onSamples?($0) }
        active.onHeartbeat = { [weak self] in self?.onHeartbeat?($0) }
        active.onConnection = { [weak self] in self?.onConnection?($0, $1) }
        active.onFailure = { [weak self] in self?.onFailure?($0) }
        active.onPeerReset = { [weak self] in self?.onPeerReset?($0) }
        active.onDroppedPacket = { [weak self] in self?.onDroppedPacket?() }
    }

    func start(host: String, port: UInt16) throws { try active.start(host: host, port: port) }
    func ping(at now: Date) throws { try active.ping(at: now) }
    func send(_ frame: ParameterOutputFrame) throws { try active.send(frame) }
    func stop() { active.stop() }
}
