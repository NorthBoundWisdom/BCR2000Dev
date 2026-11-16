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
    private var stopResult: [String]?
    private var lastFaultGeneration: UInt?
    private let peerClock: @Sendable () -> Double

    public convenience init(map: HardwareMap, configuration: SurfaceConfiguration,
                            report: @escaping @MainActor (JSONValue) -> Void = { _ in }) throws
    {
        try self.init(map: map, configuration: configuration, api: SystemOwnedVirtualMIDIAPI(), report: report)
    }

    init(map: HardwareMap, configuration: SurfaceConfiguration, api: any OwnedVirtualMIDIAPI,
         report: @escaping @MainActor (JSONValue) -> Void = { _ in },
         peerClock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) throws
    {
        self.peerClock = peerClock
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
            Task { @MainActor [weak self] in self?.publishFault(reason, snapshot: snapshot) }
        }
    }

    public func start() async throws {
        let snapshot = try await graph.start()
        guard !stopped else { throw OwnedVirtualError.disconnected }
        connection = snapshot; onConnection?(snapshot)
        guard !stopped, graph.isCurrent(snapshot) else { throw OwnedVirtualError.disconnected }
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

        fields["audit"] = audit
        report(.object(fields))
    }

    private func fault(_ reason: String) {
        guard !stopped else { return }
        let snapshot = graph.invalidate(reason)
        publishFault(snapshot.lastError ?? reason, snapshot: snapshot)
    }

    private func publishFault(_ reason: String, snapshot: MIDIConnectionSnapshot) {
        guard !stopped, graph.isCurrent(snapshot), lastFaultGeneration != snapshot.transportGeneration else { return }
        lastFaultGeneration = snapshot.transportGeneration
        peerReader?.stop()
        connection = snapshot; onConnection?(snapshot)
        guard !stopped, graph.isCurrent(snapshot) else { return }
        event("fault", detail: reason)
    }

    private func receive(_ frame: OwnedVirtualInput) {
        guard !stopped, graph.admits(frame.endpoint), connection.isConnected,
              connection.transportGeneration.map(UInt64.init) == frame.endpoint.connectionGeneration else { return }
        let lag = ProcessInfo.processInfo.systemUptime - frame.receivedAt
        guard lag.isFinite, (0 ... 2).contains(lag) else { fault("owned_input_handoff_lag"); return }
        let batch = SurfaceInputBatch(messages: frame.messages, endpoint: frame.endpoint)
        if let onInputBatch { onInputBatch(batch) } else { onMessages?(batch.messages) }
        guard !stopped, graph.admits(frame.endpoint) else { return }
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
        guard !stopped else { throw OwnedVirtualError.disconnected }
        try message.validate()
        guard connection.isConnected,
              let control = map.control(for: message.controlID) else { throw OwnedVirtualError.invalidMessage }
        _ = try entry(control)
        guard message.controlID.kind != .nrpn else { throw OwnedVirtualError.invalidMessage }
        do { try graph.send(message) }
        catch { fault("owned_display_transport_failed"); throw error }
        guard !stopped else { throw OwnedVirtualError.disconnected }
        event("display_transport_accepted")
    }

    /// Private inherited-FD commands only. This function is not a registered RPC or MIDI destination.
    func peer(_ value: JSONValue) throws {
        guard !stopped else { throw OwnedVirtualError.disconnected }
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
            do { connection = try graph.disconnect() }
            catch { publishFault(
                graph.currentSnapshot.lastError ?? "owned_disconnect_failed",
                snapshot: graph.currentSnapshot
            ); throw error }
            onConnection?(connection)
            if !stopped { event("disconnected") }
        case "reconnect":
            guard Set(fields.keys) == ["operation"] else { throw OwnedVirtualError.invalidPeer }
            do { connection = try graph.reconnect() }
            catch { publishFault(
                graph.currentSnapshot.lastError ?? "owned_connect_failed",
                snapshot: graph.currentSnapshot
            ); throw error }
            onConnection?(connection)
            if !stopped { event("reconnected") }
        default: throw OwnedVirtualError.invalidPeer
        }
    }

    public func startPeer(fd: Int32) throws {
        guard peerReader == nil, !stopped, connection.isConnected else { throw OwnedVirtualError.invalidPeer }
        let graph = graph
        peerReader = try OwnedVirtualPeerReader(fd: fd, scope: { graph.peerGeneration }, now: peerClock,
                                                fault: { graph.requestFault($0) })
        { [weak self] batch in
            Task { @MainActor [weak self] in
                defer { batch.ticket.finish() }
                self?.consume(batch)
            }
        }
        event("private_peer_started")
    }

    private func consume(_ batch: OwnedPeerBatch) {
        guard !stopped else { return }
        do {
            for line in batch.lines {
                guard !stopped else { return }
                let lag = peerClock() - batch.receivedAt
                guard lag.isFinite, (0 ... 2).contains(lag) else { fault("private_peer_handoff_lag"); return }
                guard graph.admitsPeer(batch.generation) else { fault("private_peer_stale_generation"); return }
                try peer(try JSONDecoder().decode(JSONValue.self, from: line))
            }
        } catch { fault("private_peer_rejected") }
    }

    public var audit: JSONValue {
        var fields = graph.audit().objectValue ?? [:]
        fields["peer_ingress"] = peerReader?.audit ?? .null
        return .object(fields)
    }

    @discardableResult
    public func stop() -> [String] {
        if let stopResult { return stopResult }
        stopped = true; peerReader?.stop(); stopResult = ["owned_cleanup_in_progress"]
        let failures = graph.stop(); stopResult = failures
        connection = MIDIConnectionSnapshot(); onConnection?(connection)
        event("stopped", detail: failures.isEmpty ? "owned_cleanup_complete" : "owned_cleanup_failed")
        return failures
    }
}

/// A private peer has its own budget, independent of native input and display receipt storage.
private final class OwnedVirtualPeerReader: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "astro.owned-virtual-peer")
    private let budget = OwnedIngressBudget(
        tasks: 16,
        units: 64,
        bytes: 65536,
        byteAccounting: "UTF-8 command bytes including line delimiters"
    )
    private var buffer = Data(), bufferAt: Double?, bufferGeneration: UInt?
    private var readCount = 0
    private var closed = false
    private let stateLock = NSLock()
    private let deliver: @Sendable (OwnedPeerBatch) -> Void
    private let fault: @Sendable (String) -> Void
    private let scope: @Sendable () -> UInt?
    private let now: @Sendable () -> Double
    init(fd: Int32, scope: @escaping @Sendable () -> UInt?, now: @escaping @Sendable () -> Double,
         fault: @escaping @Sendable (String) -> Void, deliver: @escaping @Sendable (OwnedPeerBatch) -> Void) throws
    {
        var info = stat()
        guard fd > STDERR_FILENO, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              fcntl(fd, F_GETFL) & O_ACCMODE != O_WRONLY else { throw OwnedVirtualError.invalidPeer }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw OwnedVirtualError.invalidPeer }
        self.deliver = deliver; self.fault = fault; self.scope = scope; self.now = now
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.read(fd) }
        source.resume()
    }

    private func reject(_ reason: String) {
        stateLock.lock(); let first = !closed; closed = true; stateLock.unlock()
        guard first else { return }
        budget.close(); source.cancel(); fault(reason)
    }

    private func read(_ fd: Int32) {
        stateLock.lock(); let isClosed = closed; stateLock.unlock()
        guard !isClosed else { return }
        let receivedAt = now(), tagged = scope()
        var bytes = [UInt8](repeating: 0, count: 4096)
        let amount = Darwin.read(fd, &bytes, bytes.count)
        if amount == 0 {
            if !buffer.isEmpty { reject("private_peer_incomplete_line") } else { stop() }
            return
        }
        if amount < 0 {
            if errno != EAGAIN && errno != EINTR { reject("private_peer_read_failed") }
            return
        }
        readCount = min(readCount, Int.max - 1) + 1
        guard let tagged else { reject("private_peer_stale_generation"); return }
        if buffer.isEmpty { bufferAt = receivedAt; bufferGeneration = tagged }
        buffer.append(contentsOf: bytes.prefix(amount))
        guard buffer.count <= 65536 else { reject("private_peer_capacity_exhausted"); return }
        var lines: [Data] = [], consumed = 0
        let firstAt = bufferAt ?? receivedAt, firstGeneration = bufferGeneration ?? tagged
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            guard !line.isEmpty, line.count <= 4096,
                  lines.count < 64 else { reject("private_peer_invalid_line"); return }
            lines.append(Data(line)); consumed += line.count + 1; buffer.removeSubrange(...end)
        }
        guard !lines.isEmpty else { return }
        guard let ticket = budget.reserve(units: lines.count, bytes: consumed) else {
            reject("private_peer_capacity_exhausted"); return
        }
        if buffer.isEmpty { bufferAt = nil; bufferGeneration = nil }
        // A partial remaining line conservatively keeps its first-byte time and scope.
        deliver(.init(lines: lines, receivedAt: firstAt, generation: firstGeneration, ticket: ticket))
    }

    var audit: JSONValue {
        queue.sync {
            var fields = budget.audit.objectValue ?? [:]
            fields["read_count"] = .number(readCount)
            fields["buffer_bytes"] = .number(buffer.count)
            fields["oldest_buffer_received_at"] = bufferAt.map(JSONValue.double) ?? .null
            return .object(fields)
        }
    }

    func stop() {
        stateLock.lock(); let first = !closed; closed = true; stateLock.unlock()
        if first { budget.close(); source.cancel() }
    }

    deinit { source.cancel() }
}
