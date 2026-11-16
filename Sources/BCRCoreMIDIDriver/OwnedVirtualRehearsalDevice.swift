import BCRFoundation
import BCRSurfaceDomain
import Darwin
import Foundation

/// Formal opt-in Release backend. The only routes are this instance's created virtual refs.
/// This is not MIDIService: preset/SysEx/selection/snapshot administration is unavailable.
@MainActor
public final class OwnedVirtualRehearsalDevice: SurfaceDevice, SurfaceInputObserving {
    public private(set) var connection = MIDIConnectionSnapshot()
    public var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    public var onInputBatch: (@MainActor (SurfaceInputBatch) -> Void)?
    public var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    private let graph: OwnedVirtualMIDIGraph
    private let map: HardwareMap
    private let configuration: SurfaceConfiguration
    private let report: @MainActor (JSONValue) -> Void
    private var peerReader: OwnedVirtualPeerReader?
    private var stopped = false

    public convenience init(map: HardwareMap, configuration: SurfaceConfiguration,
                            report: @escaping @MainActor (JSONValue) -> Void = { _ in }) throws
    {
        try self.init(map: map, configuration: configuration, api: SystemOwnedVirtualMIDIAPI(), report: report)
    }

    init(map: HardwareMap, configuration: SurfaceConfiguration, api: any OwnedVirtualMIDIAPI,
         report: @escaping @MainActor (JSONValue) -> Void = { _ in }) throws
    {
        try map.validate(); try configuration.validate()
        self.map = map; self.configuration = configuration; self.report = report
        graph = OwnedVirtualMIDIGraph(api: api)
        graph.onInput = { [weak self] frame in
            Task { @MainActor [weak self] in
                defer { frame.ticket.finish() }
                self?.receive(frame)
            }
        }
        graph.onFault = { [weak self] reason, snapshot in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.graph.isCurrent(snapshot) else { return }
                self.connection = snapshot; self.onConnection?(snapshot)
                self.event("fault", detail: reason)
            }
        }
    }

    public func start() async throws {
        let snapshot = try await graph.start()
        guard !stopped else { throw OwnedVirtualError.disconnected }
        connection = snapshot; onConnection?(snapshot)
        event("connected")
    }

    private func event(_ name: String, detail: String? = nil) {
        var fields: [String: JSONValue] = ["event": .string("owned_virtual." + name),
                                           "owned_virtual_rehearsal": .bool(true), "physical_evidence": .bool(false),
                                           "hardware_qualified": .bool(false)]
        if let detail { fields["detail"] = .string(detail) }
        fields["source"] = .string("hardware")
        fields["connection_generation"] = .number(Int(connection.transportGeneration ?? 0))
        fields["source_endpoint_id"] = connection.connectedSourceID.map { .number(Int($0)) } ?? .null

        fields["audit"] = graph.audit()
        report(.object(fields))
    }

    private func fault(_ reason: String) {
        connection = graph.invalidate(reason); onConnection?(connection)
        event("fault", detail: reason)
    }

    private func receive(_ frame: OwnedVirtualInput) {
        guard !stopped, graph.admits(frame.endpoint), connection.isConnected,
              connection.transportGeneration.map(UInt64.init) == frame.endpoint.connectionGeneration else { return }
        let lag = ProcessInfo.processInfo.systemUptime - frame.receivedAt
        guard lag.isFinite, (0 ... 2).contains(lag) else { fault("owned_input_handoff_lag"); return }
        let batch = SurfaceInputBatch(messages: frame.messages, endpoint: frame.endpoint)
        if let onInputBatch { onInputBatch(batch) } else { onMessages?(batch.messages) }
        event("input_callback")
    }

    private func entry(_ control: BCRControlID) throws -> HardwareMapEntry {
        guard let entry = map.entries.first(where: { $0.control == control }), entry.visualizationOnly != true,
              entry.midi.kind != .nrpn,
              !control.isContinuous || configuration.assignment(for: control)?.encoderMode == nil ||
              configuration.assignment(for: control)?.encoderMode == .absolute
        else { throw OwnedVirtualError.invalidMessage }
        return entry
    }

    public func send(_ message: MIDIVoiceMessage) throws {
        try message.validate()
        guard connection.isConnected,
              let control = map.control(for: message.controlID) else { throw OwnedVirtualError.invalidMessage }
        _ = try entry(control)
        guard message.controlID.kind != .nrpn else { throw OwnedVirtualError.invalidMessage }
        do { try graph.send(message) }
        catch { fault("owned_display_transport_failed"); throw error }
        event("display_transport_accepted")
    }

    /// Private inherited-FD commands only. This function is not a registered RPC or MIDI destination.
    func peer(_ value: JSONValue) throws {
        guard let fields = value.objectValue, let operation = fields["operation"]?.stringValue else {
            throw OwnedVirtualError.invalidPeer
        }
        switch operation {
        case "input":
            guard Set(fields.keys) == ["operation", "control", "value"],
                  let rawControl = fields["control"],
                  let raw = fields["value"] else { throw OwnedVirtualError.invalidPeer }
            let control = try rawControl.decoded(BCRControlID.self)
            let entry = try entry(control)
            let amount: UInt8
            if control.isContinuous {
                guard let integer = raw.exactIntValue,
                      (0 ... 127).contains(integer) else { throw OwnedVirtualError.invalidPeer }
                amount = UInt8(integer)
            } else {
                guard let flag = raw.boolValue else { throw OwnedVirtualError.invalidPeer }
                amount = flag ? 127 : 0
            }
            try graph.publish(MIDI1UMPCodec.feedback(control: entry.midi, value: amount))
            event("private_input_published")
        case "disconnect":
            guard Set(fields.keys) == ["operation"] else { throw OwnedVirtualError.invalidPeer }
            connection = try graph.disconnect(); onConnection?(connection); event("disconnected")
        case "reconnect":
            guard Set(fields.keys) == ["operation"] else { throw OwnedVirtualError.invalidPeer }
            connection = try graph.reconnect(); onConnection?(connection); event("reconnected")
        default: throw OwnedVirtualError.invalidPeer
        }
    }

    public func startPeer(fd: Int32) throws {
        guard peerReader == nil, !stopped, connection.isConnected else { throw OwnedVirtualError.invalidPeer }
        peerReader = try OwnedVirtualPeerReader(fd: fd) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                do {
                    switch result {
                    case let .success(lines): for line in lines { try self.peer(try JSONDecoder().decode(
                            JSONValue.self,
                            from: line
                        )) }
                    case let .failure(error): throw error
                    }
                } catch { self.fault("private_peer_rejected") }
            }
        }
        event("private_peer_started")
    }

    public var audit: JSONValue { graph.audit() }
    @discardableResult
    public func stop() -> [String] {
        guard !stopped else { return [] }
        stopped = true; peerReader?.stop(); peerReader = nil
        let failures = graph.stop()
        connection = MIDIConnectionSnapshot(); onConnection?(connection)
        event("stopped", detail: failures.isEmpty ? "owned_cleanup_complete" : "owned_cleanup_failed")
        return failures
    }
}

private final class OwnedVirtualPeerReader: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "astro.owned-virtual-peer")
    private var buffer = Data()
    private var closed = false
    private let stateLock = NSLock()
    private let deliver: @Sendable (Result<[Data], OwnedVirtualError>) -> Void
    init(fd: Int32, deliver: @escaping @Sendable (Result<[Data], OwnedVirtualError>) -> Void) throws {
        var info = stat()
        guard fd > STDERR_FILENO, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else {
            throw OwnedVirtualError.invalidPeer
        }
        let ownedFD = fd // Explicit ownership transfer of this inherited read end only.
        _ = fcntl(ownedFD, F_SETFL, fcntl(ownedFD, F_GETFL) | O_NONBLOCK)
        self.deliver = deliver
        source = DispatchSource.makeReadSource(fileDescriptor: ownedFD, queue: queue)
        source.setCancelHandler { close(ownedFD) }
        source.setEventHandler { [weak self] in self?.read(ownedFD) }
        source.resume()
    }

    private func read(_ fd: Int32) {
        stateLock.lock(); let isClosed = closed; stateLock.unlock()
        guard !isClosed else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let amount = Darwin.read(fd, &bytes, bytes.count)
        if amount == 0 {
            if !buffer.isEmpty { deliver(.failure(.invalidPeer)) }
            stop(); return
        }
        if amount < 0 {
            if errno != EAGAIN && errno != EINTR { deliver(.failure(.invalidPeer)); stop() }
            return
        }
        buffer.append(contentsOf: bytes.prefix(amount))
        guard buffer.count <= 65536 else { deliver(.failure(.invalidPeer)); stop(); return }
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            guard !line.isEmpty, line.count <= 4096,
                  lines.count < 64 else { deliver(.failure(.invalidPeer)); stop(); return }
            lines.append(Data(line)); buffer.removeSubrange(...end)
        }
        if !lines.isEmpty { deliver(.success(lines)) }
    }

    func stop() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true; stateLock.unlock(); source.cancel()
    }

    deinit { source.cancel() }
}
