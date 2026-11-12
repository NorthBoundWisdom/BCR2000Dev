import BCRAgentCore
import Foundation

enum OutputTransportKind: String, Codable, CaseIterable { case osc, webSocket, rosbridge }

@MainActor
final class OutputTransportRouter: MonotonicOutputTransport {
    var onSamples: (@MainActor ([ParameterSample]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var onPolicySamples: (@MainActor ([SharedParameterSample]) -> Void)?
    var onPolicyHeartbeat: (@MainActor (Double) -> Void)?
    var onPolicyPeerReset: (@MainActor (Double) -> Void)?
    var supportsMonotonicReceipts: Bool { (active as? any MonotonicOutputTransport)?.supportsMonotonicReceipts == true }
    var isConnected: Bool { active.isConnected }
    private var active: any OutputTransport
    private let factory: @MainActor (OutputTransportKind) -> any OutputTransport
    private var kind: OutputTransportKind = .osc
    private var generation = UUID()
    init(factory: (@MainActor (OutputTransportKind) -> any OutputTransport)? = nil) {
        let make: @MainActor (OutputTransportKind) -> any OutputTransport = factory ?? { kind in
            switch kind {
            case .osc: OSCParameterAdapter()
            case .webSocket: WebSocketParameterAdapter()
            case .rosbridge: WebSocketParameterAdapter(rosbridge: true)
            }
        }
        self.factory = make
        active = make(.osc)
        attach()
    }

    func select(_ kind: OutputTransportKind) throws {
        if self.kind == kind { try active.select(kind); return }
        let next = factory(kind)
        try next.select(kind)
        generation = UUID()
        detach()
        active.stop()
        self.kind = kind
        active = next
        attach()
    }

    private func detach() {
        active.onSamples = nil; active.onHeartbeat = nil; active.onConnection = nil
        active.onFailure = nil; active.onPeerReset = nil; active.onDroppedPacket = nil
        if let policy = active as? any MonotonicOutputTransport {
            policy.onPolicySamples = nil; policy.onPolicyHeartbeat = nil; policy.onPolicyPeerReset = nil
        }
    }

    private func attach() {
        let revision = generation
        active
            .onSamples = { [weak self] in
                guard let self, self.generation == revision else { return }; self.onSamples?($0)
            }
        active
            .onHeartbeat = { [weak self] in
                guard let self, self.generation == revision else { return }; self.onHeartbeat?($0)
            }
        active
            .onConnection = { [weak self] in
                guard let self, self.generation == revision else { return }; self.onConnection?(
                    $0,
                    $1
                )
            }
        active
            .onFailure = { [weak self] in
                guard let self, self.generation == revision else { return }; self.onFailure?($0)
            }
        active
            .onPeerReset = { [weak self] in
                guard let self, self.generation == revision else { return }; self.onPeerReset?($0)
            }
        active
            .onDroppedPacket = { [weak self] in
                guard let self, self.generation == revision else { return }; self.onDroppedPacket?()
            }
        if let policy = active as? any MonotonicOutputTransport {
            policy.onPolicySamples = { [weak self] samples in
                guard let self, self.generation == revision else { return }; self.onPolicySamples?(samples)
            }
            policy.onPolicyHeartbeat = { [weak self] time in
                guard let self, self.generation == revision else { return }; self.onPolicyHeartbeat?(time)
            }
            policy.onPolicyPeerReset = { [weak self] time in
                guard let self, self.generation == revision else { return }; self.onPolicyPeerReset?(time)
            }
        }
    }

    func start(host: String, port: UInt16) throws {
        try active.select(kind)
        generation = UUID(); attach()
        try active.start(host: host, port: port)
    }

    func ping(at now: Date) throws { try active.ping(at: now) }
    func ping(atMonotonic time: Double) throws {
        guard let policy = active as? any MonotonicOutputTransport, policy.supportsMonotonicReceipts else {
            throw MotionSafetyError(L10n.text("当前适配器不支持单调接收时间"))
        }
        try policy.ping(atMonotonic: time)
    }

    func send(_ frame: ParameterOutputFrame) throws { try active.send(frame) }
    func stop() { generation = UUID(); detach(); active.stop() }
}
