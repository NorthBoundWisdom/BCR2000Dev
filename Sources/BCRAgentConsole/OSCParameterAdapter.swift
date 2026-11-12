import BCRAgentCore
import Foundation
import Network

@MainActor
protocol OutputTransport: ParameterSink, ParameterSource {
    var onConnection: (@MainActor (Bool, String?) -> Void)? { get set }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    var onPeerReset: (@MainActor (Date) -> Void)? { get set }
    var onDroppedPacket: (@MainActor () -> Void)? { get set }
    func select(_ kind: OutputTransportKind) throws
    func start(host: String, port: UInt16) throws
    func ping(at now: Date) throws
    func stop()
}

extension OutputTransport {
    /// Existing injected transports are explicitly OSC-only unless they declare otherwise.
    func select(_ kind: OutputTransportKind) throws {
        guard kind == .osc else { throw MotionSafetyError(L10n.text("当前适配器不支持所选输出协议")) }
    }
}

/// The connected UDP socket only accepts replies from the configured peer. Decoding and receipt
/// timestamps happen on its serial queue; callbacks hand immutable values to the main actor.
@MainActor
final class OSCParameterAdapter: MonotonicOutputTransport {
    private(set) var isConnected = false
    var onSamples: (@MainActor ([ParameterSample]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var onPolicySamples: (@MainActor ([SharedParameterSample]) -> Void)?
    var onPolicyHeartbeat: (@MainActor (Double) -> Void)?
    var onPolicyPeerReset: (@MainActor (Double) -> Void)?
    private let monotonic: @Sendable () -> Double
    private let wallClock: @Sendable () -> Date
    private let receiveCapacity: Int
    private var receiver: Task<Void, Never>?
    private var incoming: AsyncThrowingStream<OutputReceivedOSC, any Error>.Continuation?
    private var serverEpoch: String?
    private var lastHeartbeatEcho: UInt32?
    var onFailure: (@MainActor (String) -> Void)?
    private var connection: NWConnection?
    private var generation = UUID()
    private var sequence: UInt32 = 0
    private var heartbeatSequence: UInt32 = 0
    private var pendingHeartbeats: [Int32: Double] = [:]
    private var lastStateSequence: UInt32?
    private let queue = DispatchQueue(label: "dev.bcragentconsole.osc")

    init(monotonic: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping @Sendable () -> Date = { .now }, receiveCapacity: Int = 64)
    {
        self.monotonic = monotonic; self.wallClock = wallClock; self.receiveCapacity = receiveCapacity
    }

    deinit { receiver?.cancel(); incoming?.finish(); connection?.cancel() }

    func start(host: String, port: UInt16) throws {
        stop()
        guard (1 ... 1024).contains(receiveCapacity) else { throw MotionSafetyError(L10n.text("外部接收队列已满")) }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, port > 0 else {
            throw MotionSafetyError(L10n.text("OSC 目标地址或端口无效"))
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        self.connection = connection
        let generation = self.generation
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.onConnection?(true, nil)
                case let .failed(error), let .waiting(error):
                    self.isConnected = false
                    self.onConnection?(false, L10n.text("OSC 连接失败：\(error.localizedDescription)"))
                default: break
                }
            }
        }
        connection.start(queue: queue)
        let inbox = AsyncThrowingStream<OutputReceivedOSC, any Error>
            .makeStream(bufferingPolicy: .bufferingOldest(receiveCapacity))
        incoming = inbox.continuation
        receiver = Task { @MainActor [weak self] in
            do {
                for try await packet in inbox.stream {
                    guard let self, self.generation == generation else { return }
                    self.handle(packet.messages, at: packet.stamp)
                }
            } catch {
                guard let self, self.generation == generation else { return }
                if error is OutputReceiveOverflow { self.onDroppedPacket?() }
                let reason = error is OutputReceiveOverflow ? L10n.text("外部接收队列已满") : error.localizedDescription
                self.stop()
                self.onFailure?(reason)
            }
        }
        let continuation = inbox.continuation
        Self.receiveLoop(connection, monotonic: monotonic, wallClock: wallClock) { result, stamp in
            switch result {
            case let .success(messages):
                switch continuation.yield(.init(messages: messages, stamp: stamp)) {
                case .enqueued: return true
                case .dropped: continuation.finish(throwing: OutputReceiveOverflow()); return false
                case .terminated: return false
                @unknown default: continuation.finish(throwing: OutputReceiveOverflow()); return false
                }
            case let .failure(error): continuation.finish(throwing: error); return false
            }
        }
    }

    func ping(at now: Date) throws { try ping(atMonotonic: monotonic()) }
    func ping(atMonotonic now: Double) throws {
        guard isConnected else { return }
        guard now.isFinite else { throw MotionSafetyError(L10n.text("心跳时间异常，禁止输出")) }
        pendingHeartbeats = pendingHeartbeats.filter { now - $0.value < 1 }
        heartbeatSequence &+= 1
        let id = Int32(bitPattern: heartbeatSequence)
        pendingHeartbeats[id] = now
        try transmit(.message(OSCMessage("/bcr/heartbeat", [.int(id)])))
    }

    func send(_ frame: ParameterOutputFrame) throws {
        try transmit(commandPacket(frame))
    }

    func stop() {
        generation = UUID()
        receiver?.cancel(); receiver = nil; incoming?.finish(); incoming = nil
        guard let connection else { isConnected = false; return }
        self.connection = nil
        pendingHeartbeats.removeAll()
        lastStateSequence = nil
        lastHeartbeatEcho = nil
        let connected = isConnected
        isConnected = false
        if connected, serverEpoch != nil {
            do {
                let data = try OSCCodec.encode(commandPacket(.init(enabled: false, values: [:])))
                connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
            } catch {
                connection.cancel()
                onFailure?(L10n.text("OSC 停止帧编码失败"))
            }
        } else { connection.cancel() }
        serverEpoch = nil
    }

    private func commandPacket(_ frame: ParameterOutputFrame) throws -> OSCPacket {
        guard let serverEpoch else { throw MotionSafetyError(L10n.text("尚未确认对端标识")) }
        sequence &+= 1
        var elements: [OSCPacket] = [
            .message(OSCMessage("/bcr/epoch", [.string(serverEpoch)])),
            .message(OSCMessage("/bcr/frame", [.int(Int32(bitPattern: sequence))])),
            .message(OSCMessage("/bcr/enable", [.int(frame.enabled ? 1 : 0)]))
        ]
        guard frame.enabled || frame.values.isEmpty else { throw MotionSafetyError(L10n.text("禁止在停止帧中发送运动值")) }
        for id in frame.values.keys.sorted() {
            let value = Float(frame.values[id]!)
            guard value.isFinite else { throw MotionSafetyError(L10n.text("OSC 输出超出 float32 范围")) }
            elements.append(.message(OSCMessage(OSCCodec.parameterAddress(id), [.float(value)])))
        }
        return .bundle(timetag: 1, elements: elements)
    }

    private func transmit(_ packet: OSCPacket) throws {
        guard isConnected, let connection else { throw MotionSafetyError(L10n.text("OSC UDP 端点未就绪")) }
        let generation = generation
        let data = try OSCCodec.encode(packet)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                let reason = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.onFailure?(L10n.text("OSC 发送失败：\(reason)"))
                }
            }
        })
    }

    private func handle(_ messages: [OSCMessage], at stamp: OutputReceiptStamp) {
        let receivedAt = stamp.monotonic
        do {
            if messages.count == 1, messages[0].address == "/bcr/heartbeat",
               messages[0].arguments.count == 2, case let .int(id) = messages[0].arguments[0],
               case let .string(epoch) = messages[0].arguments[1], epoch.utf8.count == 32
            {
                let echo = UInt32(bitPattern: id)
                if let previous = lastHeartbeatEcho,
                   Int32(bitPattern: echo &- previous) <= 0 { onDroppedPacket?(); return }
                if let sent = pendingHeartbeats.removeValue(forKey: id),
                   receivedAt >= sent, receivedAt - sent <= 0.3
                {
                    let previousEpoch = serverEpoch
                    serverEpoch = epoch
                    if let previous = previousEpoch, previous != epoch {
                        lastStateSequence = nil
                        onPolicyPeerReset?(receivedAt); onPeerReset?(stamp.wall)
                    }
                    lastHeartbeatEcho = echo
                    onPolicyHeartbeat?(receivedAt); onHeartbeat?(stamp.wall)
                } else { onDroppedPacket?() }
                return
            }
            guard messages.count >= 3, messages[0].address == "/bcr/state/epoch",
                  messages[0].arguments.count == 1, case let .string(epoch) = messages[0].arguments[0],
                  messages[1].address == "/bcr/state/frame", messages[1].arguments.count == 1,
                  case let .int(rawSequence) = messages[1].arguments[0]
            else {
                throw MotionSafetyError(L10n.text("OSC 回传缺少对端标识/状态帧序号"))
            }
            guard epoch == serverEpoch else { onDroppedPacket?(); return }
            let sequence = UInt32(bitPattern: rawSequence)
            if let previous = lastStateSequence,
               Int32(bitPattern: sequence &- previous) <= 0 { onDroppedPacket?(); return }
            var samples: [SharedParameterSample] = []
            var seen = Set<ParameterID>()
            for message in messages.dropFirst(2) {
                let id = try OSCCodec.parameterID(message.address)
                guard seen.insert(id).inserted, message.arguments.count == 1,
                      case let .float(value) = message.arguments[0], value.isFinite
                else {
                    throw MotionSafetyError(L10n.text("OSC 回传参数重复或数值无效"))
                }
                samples.append(.init(id: id, value: Double(value), receivedAt: receivedAt))
            }
            guard !samples.isEmpty else { throw MotionSafetyError(L10n.text("OSC 状态帧为空")) }
            lastStateSequence = sequence
            onPolicySamples?(samples)
            onSamples?(samples.map { .init(id: $0.id, value: $0.value, receivedAt: stamp.wall) })
        } catch { onFailure?(error.localizedDescription) }
    }

    private nonisolated static func receiveLoop(
        _ connection: NWConnection,
        monotonic: @escaping @Sendable () -> Double,
        wallClock: @escaping @Sendable () -> Date,
        handler: @escaping @Sendable (Result<[OSCMessage], MotionSafetyError>, OutputReceiptStamp) -> Bool
    ) {
        connection.receiveMessage { data, _, _, error in
            let received = OutputReceiptStamp(monotonic: monotonic(), wall: wallClock())
            if let error {
                _ = handler(
                    .failure(MotionSafetyError(L10n.text("OSC 接收失败：\(error.localizedDescription)"))),
                    received
                ); return
            }
            guard let data else { _ = handler(.failure(MotionSafetyError(L10n.text("OSC 接收端已关闭"))), received); return }
            do {
                guard handler(.success(try OSCCodec.immediateMessages(OSCCodec.decode(data))), received) else { return }
            } catch { guard handler(.failure(MotionSafetyError(error.localizedDescription)), received) else { return } }
            receiveLoop(connection, monotonic: monotonic, wallClock: wallClock, handler: handler)
        }
    }
}
