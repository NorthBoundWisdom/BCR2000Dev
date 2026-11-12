import BCRAgentCore
import Foundation

/// ROS 2 uses rosbridge and std_msgs/msg/String envelopes carrying the same validated link frames.
@MainActor
final class WebSocketParameterAdapter: MonotonicOutputTransport {
    private(set) var isConnected = false
    var onSamples: (@MainActor ([ParameterSample]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var onPolicySamples: (@MainActor ([SharedParameterSample]) -> Void)?
    var onPolicyHeartbeat: (@MainActor (Double) -> Void)?
    var onPolicyPeerReset: (@MainActor (Double) -> Void)?
    private let monotonic: @Sendable () -> Double
    private let wallClock: @Sendable () -> Date
    private var producer: Task<Void, Never>?
    private var incoming: AsyncThrowingStream<OutputReceivedBytes, any Error>.Continuation?
    private let rosbridge: Bool
    private let queueLimit: Int
    private let receiveCapacity: Int
    private let writeMessage: @MainActor (URLSessionWebSocketTask, String) async throws -> Void
    private var link = SharedJSONParameterLink(session: UUID().uuidString)
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var outgoing: AsyncStream<String>.Continuation?
    private var queued = 0
    private var generation = UUID()
    init(rosbridge: Bool = false, queueLimit: Int = 64, receiveCapacity: Int = 64,
         writeMessage: (@MainActor (URLSessionWebSocketTask, String) async throws -> Void)? = nil,
         monotonic: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping @Sendable () -> Date = { .now })
    {
        self.monotonic = monotonic; self.wallClock = wallClock
        self.rosbridge = rosbridge
        self.queueLimit = queueLimit; self.receiveCapacity = receiveCapacity
        self.writeMessage = writeMessage ?? { socket, message in try await socket.send(.string(message)) }
    }

    func select(_ kind: OutputTransportKind) throws {
        guard kind == (rosbridge ? .rosbridge : .webSocket)
        else { throw MotionSafetyError(L10n.text("当前适配器不支持所选输出协议")) }
    }

    deinit {
        producer?.cancel(); incoming?.finish(); receiver?.cancel(); sender?.cancel(); socket?.cancel(
            with: .goingAway,
            reason: nil
        ); session?
            .invalidateAndCancel()
    }

    func start(host: String, port: UInt16) throws {
        stop()
        guard (1 ... 1024).contains(queueLimit) else { throw MotionSafetyError(L10n.text("外部输出队列已满")) }
        guard (1 ... 1024).contains(receiveCapacity) else { throw MotionSafetyError(L10n.text("外部接收队列已满")) }
        var components = URLComponents()
        components.scheme = "ws"; components.host = host; components.port = Int(port); components.path = "/"
        guard port > 0, let url = components.url, !host.isEmpty else {
            throw MotionSafetyError(L10n.text("输出地址、端口或设置版本无效"))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        self.session = session
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 1_048_576
        self.socket = socket
        link = SharedJSONParameterLink(session: UUID().uuidString)
        let revision = generation
        let stream = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(queueLimit))
        outgoing = stream.continuation
        let writeMessage = writeMessage
        sender = Task { [weak self] in
            do {
                for await message in stream.stream {
                    try Task.checkCancellation()
                    try await writeMessage(socket, message)
                    guard let self, self.generation == revision else { return }
                    self.queued -= 1
                }
            } catch {
                guard let self, self.generation == revision else { return }
                self.fail(error)
            }
        }
        socket.resume()
        let inbox = AsyncThrowingStream<OutputReceivedBytes, any Error>
            .makeStream(bufferingPolicy: .bufferingOldest(receiveCapacity))
        incoming = inbox.continuation
        let monotonic = monotonic, wallClock = wallClock
        // URLSession messages are read continuously off the main actor. Capture age before
        // the bounded handoff; waiting for MainActor before stamping would make backlog fresh.
        producer = Task.detached {
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let stamp = OutputReceiptStamp(monotonic: monotonic(), wall: wallClock())
                    let data: Data
                    switch message {
                    case let .string(text): data = Data(text.utf8)
                    case let .data(bytes): data = bytes
                    @unknown default: throw MotionSafetyError(L10n.text("外部状态消息无效"))
                    }
                    switch inbox.continuation.yield(.init(data: data, stamp: stamp)) {
                    case .enqueued: break
                    case .dropped: inbox.continuation.finish(throwing: OutputReceiveOverflow()); return
                    case .terminated: return
                    @unknown default: inbox.continuation.finish(throwing: OutputReceiveOverflow()); return
                    }
                }
            } catch { inbox.continuation.finish(throwing: error) }
        }
        receiver = Task { [weak self] in
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    socket.sendPing { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                if let self {
                    guard self.generation == revision else { return }
                    self.isConnected = true
                    if self.rosbridge {
                        for topic in ["/bcr/command", "/bcr/heartbeat/request"] {
                            try self.enqueue(
                                .object([
                                    "op": .string("advertise"),
                                    "topic": .string(topic),
                                    "type": .string("std_msgs/msg/String")
                                ]),
                                raw: true
                            )
                        }
                        for topic in ["/bcr/state", "/bcr/heartbeat"] {
                            try self.enqueue(
                                .object([
                                    "op": .string("subscribe"),
                                    "topic": .string(topic),
                                    "type": .string("std_msgs/msg/String")
                                ]),
                                raw: true
                            )
                        }
                    }
                    self.onConnection?(true, nil)
                }
                for try await packet in inbox.stream {
                    guard let self, self.generation == revision else { return }
                    let data = packet.data
                    var value = try JSONDecoder().decode(JSONValue.self, from: data)
                    if self.rosbridge {
                        guard let object = value.objectValue, object["op"] == .string("publish"),
                              ["/bcr/state", "/bcr/heartbeat"].contains(object["topic"]?.stringValue ?? ""),
                              let text = object["msg"]?.objectValue?["data"]?.stringValue
                        else {
                            self.onDroppedPacket?(); continue
                        }
                        value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                    }
                    switch try self.link.receive(value, at: packet.stamp.monotonic) {
                    case let .heartbeat(time, reset):
                        if reset { self.onPolicyPeerReset?(time); self.onPeerReset?(packet.stamp.wall) }
                        self.onPolicyHeartbeat?(time); self.onHeartbeat?(packet.stamp.wall)
                    case let .samples(samples):
                        self.onPolicySamples?(samples)
                        self
                            .onSamples?(samples
                                .map { .init(id: $0.id, value: $0.value, receivedAt: packet.stamp.wall) })
                    case .ignored: self.onDroppedPacket?()
                    }
                }
            } catch {
                guard let self, self.generation == revision else { return }
                if error is OutputReceiveOverflow { self.onDroppedPacket?() }
                self.fail(error is OutputReceiveOverflow ? MotionSafetyError(L10n.text("外部接收队列已满")) : error)
            }
        }
    }

    func ping(at now: Date) throws { try ping(atMonotonic: monotonic()) }
    func ping(atMonotonic now: Double) throws {
        guard isConnected else { return }
        guard now.isFinite else { throw MotionSafetyError(L10n.text("心跳时间异常，禁止输出")) }
        try enqueue(link.ping(at: now))
    }

    func send(_ frame: ParameterOutputFrame) throws {
        guard isConnected else { throw MotionSafetyError(L10n.text("外部连接尚未就绪")) }
        try enqueue(link.command(frame))
    }

    private func enqueue(_ value: JSONValue, raw: Bool = false) throws {
        guard queued < queueLimit, let outgoing else {
            let error = MotionSafetyError(L10n.text("外部输出队列已满"))
            fail(error)
            throw error
        }
        let payload: JSONValue
        if rosbridge && !raw {
            let topic = value.objectValue?["type"] == .string("ping") ? "/bcr/heartbeat/request" : "/bcr/command"
            payload = .object([
                "op": .string("publish"),
                "topic": .string(topic),
                "msg": .object(["data": .string(try value.jsonText)])
            ])
        } else { payload = value }
        let result = outgoing.yield(try payload.jsonText)
        if case .enqueued = result { queued += 1 }
        else {
            let error = MotionSafetyError(L10n.text("外部输出队列已满"))
            fail(error)
            throw error
        }
    }

    private func fail(_ error: any Error) {
        tearDown(graceful: false)
        onFailure?(error.localizedDescription)
    }

    func stop() { tearDown(graceful: true) }
    private func tearDown(graceful: Bool) {
        let socket = socket
        let session = session
        let stopFrame = try? link.command(.init(enabled: false, values: [:]))
        generation = UUID()
        isConnected = false
        outgoing?.finish(); outgoing = nil
        sender?.cancel(); sender = nil
        producer?.cancel(); producer = nil; incoming?.finish(); incoming = nil
        receiver?.cancel(); receiver = nil
        self.socket = nil; self.session = nil; queued = 0
        guard let socket else { session?.invalidateAndCancel(); return }
        guard graceful else {
            socket.cancel(with: .goingAway, reason: nil)
            session?.invalidateAndCancel()
            return
        }
        let rosbridge = rosbridge
        Task {
            let timeout = Task {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                socket.cancel(with: .goingAway, reason: nil)
                session?.invalidateAndCancel()
            }
            defer { timeout.cancel() }
            if let stopFrame {
                let payload: JSONValue
                if rosbridge { payload = .object([
                    "op": .string("publish"),
                    "topic": .string("/bcr/command"),
                    "msg": .object(["data": .string((try? stopFrame.jsonText) ?? "")])
                ]) } else { payload = stopFrame }
                if let text = try? payload.jsonText { try? await socket.send(.string(text)) }
            }
            socket.cancel(with: .goingAway, reason: nil)
            session?.invalidateAndCancel()
        }
    }
}
