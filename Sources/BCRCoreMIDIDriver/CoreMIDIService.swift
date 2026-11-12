import BCRFoundation
import BCRSurfaceDomain
import CoreMIDI
import Foundation

enum CoreMIDIServiceError: Error, LocalizedError {
    case operation(name: String, status: OSStatus)
    case outputUnavailable
    case eventListFull

    var errorDescription: String? {
        switch self {
        case let .operation(name, status):
            L10n.text("\(name) 失败（OSStatus \(status)）")
        case .outputUnavailable:
            L10n.text("BCR2000 输出端口尚未连接")
        case .eventListFull:
            L10n.text("无法构造 MIDI Event List")
        }
    }
}

@MainActor
public protocol MIDIService: SurfaceDevice {
    func start() throws
    func selectEndpoints(_ selection: MIDIEndpointSelection)
    var supportsSnapshotReadback: Bool { get }
    func readSnapshot(expected: Set<MIDIControlID>) async throws -> [MIDIVoiceMessage]
    var supportsStartupConfiguration: Bool { get }
    func configureStartup(_ program: MIDIStartupProgram) async throws
    /// Read-only dump of the current temporary preset (BCL frames, `$rev` … `$end`).
    func readCurrentPreset() async throws -> Data
    /// Read-only names of the temporary preset and the 32 memory presets (short replies, no dump).
    func readPresetNames() async throws -> BCRPresetNames
    /// Read-only dump of memory preset 1…32. Slow (~12–15 s on firmware 1.10, display busy meanwhile).
    func readMemoryPreset(_ number: Int) async throws -> Data
    /// Sends BCL frames one at a time, each acknowledged by the device. No store unless a frame says so.
    func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws
}

public extension MIDIService {
    var supportsStartupConfiguration: Bool { false }
    func configureStartup(_ program: MIDIStartupProgram) async throws { throw MIDIStartupError.invalidProgram }
    func readCurrentPreset() async throws -> Data { throw MIDIStartupError.invalidProgram }
    func readPresetNames() async throws -> BCRPresetNames { throw MIDIStartupError.invalidProgram }
    func readMemoryPreset(_ number: Int) async throws -> Data { throw MIDIStartupError.invalidProgram }
    func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws {
        throw MIDIStartupError.invalidProgram
    }

    var supportsSnapshotReadback: Bool { false }
    func readSnapshot(expected: Set<MIDIControlID>) async throws -> [MIDIVoiceMessage] {
        throw HardwareSnapshotError.invalid
    }
}

enum CoreMIDIEndpointAvailability {
    static func isUsable(status: OSStatus, offline: Int32) -> Bool {
        status == noErr ? offline == 0 : status == kMIDIUnknownProperty
    }
}

/// Main-actor device boundary. The transport only decodes and hands off value batches;
/// connection state and session callbacks are accessed exclusively on the main actor.
@MainActor
public final class CoreMIDIService: MIDIService {
    public var supportsStartupConfiguration: Bool { true }
    static let snapshotRequest: [UInt8] = [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x43, 0xF7]
    public var supportsSnapshotReadback: Bool { true }
    public private(set) var connection = MIDIConnectionSnapshot()
    public var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    public var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    private var transport: CoreMIDITransport?
    private var selection: MIDIEndpointSelection
    private var snapshotID: UUID?
    private var snapshotContinuation: CheckedContinuation<[MIDIVoiceMessage], any Error>?
    private var snapshotExpected: Set<MIDIControlID> = []
    private var snapshotValues: [MIDIControlID: MIDIVoiceMessage] = [:]
    private var snapshotActivity: Double = 0
    private var snapshotTask: Task<Void, Never>?
    private var startupID: UUID?
    private var ackIndex: Int?
    private var ackID: UUID?
    private var ackContinuation: CheckedContinuation<Void, any Error>?
    private var ackTimeout: Task<Void, Never>?
    private var sysEx = MIDISysEx7Assembler()
    private var inputGeneration: UInt = 0
    private var dumpID: UUID?
    private var dumpFrames: [[UInt8]] = []
    private var dumpActivity: Double = 0
    private var dumpContinuation: CheckedContinuation<Data, any Error>?
    private var dumpTask: Task<Void, Never>?
    static let presetDumpRequest: [UInt8] = [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x40, 0x7F, 0xF7]
    private var namesID: UUID?
    private var names: [Int: String] = [:]
    private var namesContinuation: CheckedContinuation<BCRPresetNames, any Error>?
    private var namesTask: Task<Void, Never>?
    /// Ordinary input is dropped only while a write or value snapshot needs the route to itself.
    private var holdsInput = false

    public init(selection: MIDIEndpointSelection = .init()) { self.selection = selection }

    public func selectEndpoints(_ selection: MIDIEndpointSelection) {
        self.selection = selection
        transport?.selectEndpoints(selection)
    }

    public func start() throws {
        guard transport == nil else { return }
        let transport = CoreMIDITransport(
            selection: selection,
            onMessages: { [weak self] messages, generation in
                Task { @MainActor [weak self] in self?.receive(messages, generation: generation) }
            },
            onSysEx: { [weak self] chunks, generation in
                Task { @MainActor [weak self] in self?.receiveSysEx(chunks, generation: generation) }
            },
            onConnection: { [weak self] snapshot, generation in
                Task { @MainActor [weak self] in
                    if self?.inputGeneration != generation, let ack = self?.ackID {
                        self?.finishAck(ack, result: .failure(CoreMIDIServiceError.outputUnavailable))
                    }
                    if self?.inputGeneration != generation, let request = self?.namesID {
                        self?.finishNames(request, result: .failure(CoreMIDIServiceError.outputUnavailable))
                    }
                    if self?.inputGeneration != generation, let dump = self?.dumpID {
                        self?.finishDump(dump, result: .failure(CoreMIDIServiceError.outputUnavailable))
                    }
                    if self?.inputGeneration != generation, let id = self?.snapshotID { self?.finishSnapshot(
                        id,
                        result: .failure(HardwareSnapshotError.invalid)
                    ) }
                    self?.inputGeneration = generation
                    self?.sysEx = MIDISysEx7Assembler()
                    self?.connection = snapshot
                    self?.onConnection?(snapshot)
                }
            }
        )
        do {
            try transport.start()
            self.transport = transport
        } catch {
            connection.lastError = error.localizedDescription
            onConnection?(connection)
            throw error
        }
    }

    public func send(_ message: MIDIVoiceMessage) throws {
        try message.validate()
        guard let transport else { throw CoreMIDIServiceError.outputUnavailable }
        try transport.send(message, expectedGeneration: inputGeneration)
    }

    public func readSnapshot(expected: Set<MIDIControlID>) async throws -> [MIDIVoiceMessage] {
        guard startupID == nil, snapshotID == nil, connection.isConnected, !expected.isEmpty,
              expected.allSatisfy({ $0.kind == .controlChange }),
              let transport else { throw HardwareSnapshotError.invalid }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                snapshotID = id; snapshotContinuation = continuation
                snapshotExpected = expected; snapshotValues = [:]
                snapshotActivity = ProcessInfo.processInfo.systemUptime
                let started = snapshotActivity
                do { try transport.sendBytes(Self.snapshotRequest, expectedGeneration: inputGeneration) }
                catch { finishSnapshot(id, result: .failure(error)); return }
                snapshotTask = Task { @MainActor [weak self] in
                    for _ in 0 ..< 60 {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self, self.snapshotID == id else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        // Snapshot has no end marker. Drain trailing button messages too, without executing them.
                        if Set(self.snapshotValues.keys).isSuperset(of: expected), now - self.snapshotActivity >= 0.3 {
                            self.finishSnapshot(id, result: .success(Array(self.snapshotValues.values))); return
                        }
                        if now - started >= 6 { break }
                    }
                    self?.finishSnapshot(id, result: .failure(HardwareSnapshotError.invalid))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishSnapshot(id, result: .failure(CancellationError())) }
        }
    }

    private func receive(_ messages: [MIDIVoiceMessage], generation: UInt) {
        guard generation == inputGeneration else { return }
        guard startupID == nil || !holdsInput else { return }
        guard let id = snapshotID else { onMessages?(messages); return }
        snapshotActivity = ProcessInfo.processInfo.systemUptime
        for message in messages where snapshotExpected.contains(message.controlID) {
            if let previous = snapshotValues[message.controlID], previous != message {
                finishSnapshot(id, result: .failure(HardwareSnapshotError.invalid)); return
            }
            snapshotValues[message.controlID] = message
        }
    }

    private func finishSnapshot(_ id: UUID, result: Result<[MIDIVoiceMessage], any Error>) {
        guard snapshotID == id else { return }
        let continuation = snapshotContinuation
        snapshotID = nil; snapshotContinuation = nil
        snapshotTask?.cancel(); snapshotTask = nil
        snapshotExpected = []; snapshotValues = [:]
        continuation?.resume(with: result)
    }

    public func configureStartup(_ program: MIDIStartupProgram) async throws {
        let frames = try program.frames()
        try await exclusiveSysEx { transport, generation in
            try transport.sendBytes(program.selectBytes, expectedGeneration: generation)
            try await Task.sleep(for: .milliseconds(150))
            try await self.acknowledged(frames, transport: transport, generation: generation, progress: { _ in })
        }
    }

    public func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws {
        guard !frames.isEmpty, frames.allSatisfy({ $0.count >= 10 && $0.first == 0xF0 && $0.last == 0xF7 &&
                $0[1 ..< $0.count - 1].allSatisfy { $0 < 0x80 } && $0[5] == 0x15 && $0[6] == 0x20 })
        else { throw MIDIStartupError.invalidProgram }
        try await exclusiveSysEx { transport, generation in
            try await self.acknowledged(frames, transport: transport, generation: generation, progress: progress)
        }
    }

    public func readCurrentPreset() async throws -> Data { try await readPreset(selector: 0x7F) }

    public func readMemoryPreset(_ number: Int) async throws -> Data {
        guard (1 ... 32).contains(number) else { throw MIDIStartupError.invalidProgram }
        return try await readPreset(selector: UInt8(number - 1))
    }

    public func readPresetNames() async throws -> BCRPresetNames {
        try await exclusiveSysEx(holdsInput: false) { transport, generation in
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                    BCRPresetNames, any Error
                >) in
                    self.namesID = id; self.names = [:]; self.namesContinuation = continuation
                    do {
                        try transport.sendBytes([0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x42, 0x7F, 0xF7],
                                                expectedGeneration: generation)
                        try transport.sendBytes([0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x42, 0x7E, 0xF7],
                                                expectedGeneration: generation)
                    } catch { self.finishNames(id, result: .failure(error)); return }
                    self.namesTask = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        self?.finishNames(id, result: .failure(MIDIStartupError.noReply))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finishNames(id, result: .failure(CancellationError())) }
            }
        }
    }

    private func finishNames(_ id: UUID, result: Result<BCRPresetNames, any Error>) {
        guard namesID == id else { return }
        let continuation = namesContinuation
        namesID = nil; namesContinuation = nil; names = [:]
        namesTask?.cancel(); namesTask = nil
        continuation?.resume(with: result)
    }

    private func readPreset(selector: UInt8) async throws -> Data {
        let request: [UInt8] = [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x40, selector, 0xF7]
        return try await exclusiveSysEx(holdsInput: false) { transport, generation in
            let id = UUID()
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                    Data,
                    any Error
                >) in
                    self.dumpID = id; self.dumpFrames = []; self.dumpContinuation = continuation
                    self.dumpActivity = ProcessInfo.processInfo.systemUptime
                    let started = self.dumpActivity
                    do { try transport.sendBytes(request, expectedGeneration: generation) }
                    catch { self.finishDump(id, result: .failure(error)); return }
                    self.dumpTask = Task { @MainActor [weak self] in
                        while true {
                            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                            guard let self, self.dumpID == id else { return }
                            let now = ProcessInfo.processInfo.systemUptime
                            if now - self.dumpActivity > 3 || now - started > 45 {
                                self.finishDump(id, result: .failure(MIDIStartupError.noReply)); return
                            }
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finishDump(id, result: .failure(CancellationError())) }
            }
        }
    }

    /// Runs one SysEx exchange while ordinary input is held back and the route must stay unchanged.
    private func exclusiveSysEx<T>(
        holdsInput: Bool = true,
        _ body: @MainActor (CoreMIDITransport, UInt) async throws -> T
    ) async throws -> T {
        guard startupID == nil, snapshotID == nil, connection.isConnected,
              let transport else { throw CoreMIDIServiceError.outputUnavailable }
        let id = UUID(), generation = inputGeneration
        startupID = id; sysEx = MIDISysEx7Assembler(); self.holdsInput = holdsInput
        defer { if startupID == id { startupID = nil; self.holdsInput = false; sysEx = MIDISysEx7Assembler() } }
        try Task.checkCancellation()
        return try await body(transport, generation)
    }

    private func acknowledged(
        _ frames: [[UInt8]], transport: CoreMIDITransport, generation: UInt,
        progress: @MainActor (Int) -> Void
    ) async throws {
        let route = connection
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            guard connection.hasSameRoute(as: route),
                  inputGeneration == generation else { throw CoreMIDIServiceError.outputUnavailable }
            let ack = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    ackID = ack; ackIndex = index; ackContinuation = continuation
                    do { try transport.sendBytes(frame, expectedGeneration: generation) }
                    catch { finishAck(ack, result: .failure(error)); return }
                    ackTimeout = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        self?.finishAck(ack, result: .failure(MIDIStartupError.noReply))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finishAck(ack, result: .failure(CancellationError())) }
            }
            progress(index + 1)
        }
    }

    private func finishDump(_ id: UUID, result: Result<Data, any Error>) {
        guard dumpID == id else { return }
        let continuation = dumpContinuation
        dumpID = nil; dumpContinuation = nil; dumpFrames = []
        dumpTask?.cancel(); dumpTask = nil
        continuation?.resume(with: result)
    }

    private func receiveSysEx(_ chunks: [MIDISysEx7Chunk], generation: UInt) {
        guard generation == inputGeneration else { return }
        for chunk in chunks {
            guard let frame = sysEx.consume(chunk) else { continue }
            if let id = dumpID, frame.count >= 10, frame.prefix(4) == [0xF0, 0, 0x20, 0x32],
               frame[5] == 0x15, frame[6] == 0x20
            {
                guard Int(frame[7]) * 128 + Int(frame[8]) == dumpFrames.count else {
                    finishDump(id, result: .failure(HardwareSnapshotError.invalid)); continue
                }
                dumpFrames.append(frame)
                dumpActivity = ProcessInfo.processInfo.systemUptime
                let text = String(decoding: frame[9 ..< frame.count - 1], as: UTF8.self)
                if text.trimmingCharacters(in: .whitespaces) == "$end" {
                    finishDump(id, result: .success(Data(dumpFrames.joined())))
                }
                continue
            }
            // Send Preset Name: F0 00 20 32 dd 15 21 00 index name(24) F7.
            if let id = namesID, frame.count == 34, frame.prefix(4) == [0xF0, 0, 0x20, 0x32],
               frame[5] == 0x15, frame[6] == 0x21, frame[7] == 0, frame[8] < 32 || frame[8] == 0x7F
            {
                names[Int(frame[8])] = String(decoding: frame[9 ..< 33], as: UTF8.self)
                if let temporary = names[0x7F], (0 ... 31).allSatisfy({ names[$0] != nil }) {
                    finishNames(id, result: .success(BCRPresetNames(
                        temporary: temporary, memory: (0 ... 31).map { names[$0]! }
                    )))
                }
                continue
            }
            guard frame.count == 11,
                  frame.prefix(4) == [0xF0, 0, 0x20, 0x32], frame[5] == 0x15, frame[6] == 0x21,
                  Int(frame[7]) * 128 + Int(frame[8]) == ackIndex, let id = ackID else { continue }
            finishAck(id, result: frame[9] == 0 ? .success(()) : .failure(MIDIStartupError.rejected(Int(frame[9]))))
        }
    }

    private func finishAck(_ id: UUID, result: Result<Void, any Error>) {
        guard ackID == id else { return }
        let c = ackContinuation
        ackID = nil; ackIndex = nil; ackContinuation = nil
        ackTimeout?.cancel(); ackTimeout = nil
        c?.resume(with: result)
    }
}

/// Owns CoreMIDI objects on a private serial queue. The receive callback only copies/decodes
/// packet words and immediately hands value types to the application.
private final class CoreMIDITransport: @unchecked Sendable {
    typealias MessageHandler = @Sendable ([MIDIVoiceMessage], UInt) -> Void
    typealias ConnectionHandler = @Sendable (MIDIConnectionSnapshot, UInt) -> Void
    typealias SysExHandler = @Sendable ([MIDISysEx7Chunk], UInt) -> Void

    private let messageHandler: MessageHandler
    private let connectionHandler: ConnectionHandler
    private let sysExHandler: SysExHandler
    private let managementQueue = DispatchQueue(label: "dev.bcragentconsole.coremidi")

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var connectedSources: [MIDIEndpointRef] = []
    private var destination: MIDIEndpointRef = 0
    private var isStarted = false
    private var selection: MIDIEndpointSelection
    private var generation: UInt = 0

    init(
        selection: MIDIEndpointSelection,
        onMessages: @escaping MessageHandler,
        onSysEx: @escaping SysExHandler,
        onConnection: @escaping ConnectionHandler
    ) {
        self.selection = selection
        messageHandler = onMessages
        sysExHandler = onSysEx
        connectionHandler = onConnection
    }

    deinit {
        stop()
    }

    public func start() throws {
        try managementQueue.sync {
            guard !isStarted else {
                return
            }

            var newClient: MIDIClientRef = 0
            let clientStatus = MIDIClientCreateWithBlock(
                "BCR Agent Console" as CFString,
                &newClient
            ) { [weak self] notification in
                guard notification.pointee.messageID == .msgSetupChanged else {
                    return
                }
                self?.managementQueue.async { [weak self] in
                    self?.reconnect()
                }
            }
            try Self.check(clientStatus, operation: L10n.text("创建 MIDI Client"))
            client = newClient

            var newInputPort: MIDIPortRef = 0
            let inputStatus = MIDIInputPortCreateWithProtocol(
                client,
                "BCR Agent Console Input" as CFString,
                ._1_0,
                &newInputPort
            ) { [weak self] eventList, context in
                guard let self else {
                    return
                }
                let (messages, chunks) = Self.decode(eventList)
                let generation = context.map { UInt(bitPattern: $0) } ?? 0
                if !messages.isEmpty {
                    self.messageHandler(messages, generation)
                }
                if !chunks.isEmpty { self.sysExHandler(chunks, generation) }
            }
            do {
                try Self.check(inputStatus, operation: L10n.text("创建 MIDI Input Port"))
            } catch {
                MIDIClientDispose(client)
                client = 0
                throw error
            }
            inputPort = newInputPort

            var newOutputPort: MIDIPortRef = 0
            let outputStatus = MIDIOutputPortCreate(
                client,
                "BCR Agent Console Output" as CFString,
                &newOutputPort
            )
            do {
                try Self.check(outputStatus, operation: L10n.text("创建 MIDI Output Port"))
            } catch {
                MIDIPortDispose(inputPort)
                MIDIClientDispose(client)
                inputPort = 0
                client = 0
                throw error
            }
            outputPort = newOutputPort
            isStarted = true
            reconnect()
        }
    }

    func stop() {
        managementQueue.sync {
            guard isStarted else {
                return
            }

            for source in connectedSources {
                MIDIPortDisconnectSource(inputPort, source)
            }
            connectedSources.removeAll()
            destination = 0

            if inputPort != 0 {
                MIDIPortDispose(inputPort)
            }
            if outputPort != 0 {
                MIDIPortDispose(outputPort)
            }
            if client != 0 {
                MIDIClientDispose(client)
            }

            inputPort = 0
            outputPort = 0
            client = 0
            isStarted = false
        }
    }

    public func send(_ message: MIDIVoiceMessage, expectedGeneration: UInt) throws {
        try message.validate()
        try sendBytes(message.midi1Bytes, expectedGeneration: expectedGeneration)
    }

    func sendBytes(_ data: [UInt8], expectedGeneration: UInt) throws {
        try managementQueue.sync {
            guard isStarted, outputPort != 0, destination != 0, generation == expectedGeneration else {
                throw CoreMIDIServiceError.outputUnavailable
            }

            var packetList = MIDIPacketList()
            let packet = MIDIPacketListInit(&packetList)
            let addedPacket = data.withUnsafeBufferPointer { bytes -> UnsafeMutablePointer<MIDIPacket>? in
                guard let baseAddress = bytes.baseAddress else {
                    return nil
                }
                return MIDIPacketListAdd(
                    &packetList,
                    MemoryLayout<MIDIPacketList>.size,
                    packet,
                    0,
                    bytes.count,
                    baseAddress
                )
            }
            guard addedPacket != nil else {
                throw CoreMIDIServiceError.eventListFull
            }

            let status = MIDISend(outputPort, destination, &packetList)
            try Self.check(status, operation: L10n.text("发送 MIDI Feedback"))
        }
    }

    public func selectEndpoints(_ selection: MIDIEndpointSelection) {
        managementQueue.async { [weak self] in
            self?.selection = selection
            self?.reconnect()
        }
    }

    private func reconnect() {
        guard isStarted else {
            return
        }
        generation &+= 1
        if generation == 0 { generation = 1 }

        for source in connectedSources {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources.removeAll()
        destination = 0

        let sources = Self.endpoints(
            count: MIDIGetNumberOfSources,
            endpointAt: MIDIGetSource
        )
        let destinations = Self.endpoints(
            count: MIDIGetNumberOfDestinations,
            endpointAt: MIDIGetDestination
        )

        var lastError: String?
        func resolve(_ endpoints: [NamedEndpoint], selectedID: Int32?) -> NamedEndpoint? {
            do {
                let value = try MIDIEndpointPolicy.resolve(
                    endpoints.map { .init(id: $0.id, name: $0.name, availabilityKnown: $0.availabilityKnown) },
                    selectedID: selectedID
                )
                return endpoints.first { $0.id == value.id }
            } catch {
                lastError = [lastError, error.localizedDescription].compactMap { $0 }.joined(separator: "；")
                return nil
            }
        }
        let selectedSource = resolve(sources, selectedID: selection.sourceID)
        let selectedDestination = resolve(destinations, selectedID: selection.destinationID)
        if let selectedSource {
            let status = MIDIPortConnectSource(
                inputPort,
                selectedSource.endpoint,
                UnsafeMutableRawPointer(bitPattern: generation)
            )
            if status == noErr { connectedSources = [selectedSource.endpoint] }
            else {
                lastError = CoreMIDIServiceError.operation(name: L10n.text("连接 \(selectedSource.name)"), status: status)
                    .localizedDescription
            }
        }
        if let selectedDestination { destination = selectedDestination.endpoint }
        var snapshot = MIDIConnectionSnapshot(
            sourceNames: sources.map(\.name), destinationNames: destinations.map(\.name),
            connectedSource: connectedSources.isEmpty ? nil : selectedSource?.name,
            connectedDestination: destination == 0 ? nil : selectedDestination?.name, lastError: lastError
        )
        snapshot.sourceEndpoints = sources
            .map { .init(id: $0.id, name: $0.name, availabilityKnown: $0.availabilityKnown) }
        snapshot.destinationEndpoints = destinations.map { .init(
            id: $0.id,
            name: $0.name,
            availabilityKnown: $0.availabilityKnown
        ) }
        snapshot.connectedSourceID = connectedSources.isEmpty ? nil : selectedSource?.id
        snapshot.connectedDestinationID = destination == 0 ? nil : selectedDestination?.id
        connectionHandler(snapshot, generation)
    }

    private struct NamedEndpoint {
        let availabilityKnown: Bool
        let endpoint: MIDIEndpointRef
        let id: Int32
        let name: String
    }

    private static func endpoints(
        count: () -> Int,
        endpointAt: (Int) -> MIDIEndpointRef
    ) -> [NamedEndpoint] {
        (0 ..< count()).compactMap { index in
            let endpoint = endpointAt(index)
            var id: Int32 = 0
            var offline: Int32 = 0
            let availabilityStatus = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            guard endpoint != 0,
                  MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr, id != 0,
                  CoreMIDIEndpointAvailability.isUsable(status: availabilityStatus, offline: offline)
            else {
                return nil
            }
            return NamedEndpoint(
                availabilityKnown: availabilityStatus == noErr,
                endpoint: endpoint,
                id: id,
                name: endpointName(endpoint) ?? L10n.text("未命名 MIDI 端点")
            )
        }
    }

    private static func endpointName(_ endpoint: MIDIEndpointRef) -> String? {
        var property: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(
            endpoint,
            kMIDIPropertyDisplayName,
            &property
        ) == noErr else {
            return nil
        }
        return property?.takeRetainedValue() as String?
    }

    private static func decode(
        _ eventList: UnsafePointer<MIDIEventList>
    ) -> ([MIDIVoiceMessage], [MIDISysEx7Chunk]) {
        guard
            let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet),
            let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)
        else {
            return ([], [])
        }

        var result: [MIDIVoiceMessage] = []
        var chunks: [MIDISysEx7Chunk] = []
        var packet = UnsafeRawPointer(eventList)
            .advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIEventPacket.self)

        for _ in 0 ..< eventList.pointee.numPackets {
            let words = UnsafeRawPointer(packet)
                .advanced(by: wordsOffset)
                .assumingMemoryBound(to: UInt32.self)
            var wordIndex = 0
            let packetWordCount = Int(packet.pointee.wordCount)
            while wordIndex < packetWordCount {
                let word = words[wordIndex]
                if let message = MIDI1UMPCodec.decode(word: word) {
                    result.append(message)
                }
                if wordIndex + 1 < packetWordCount,
                   let chunk = MIDISysEx7Chunk(word0: word, word1: words[wordIndex + 1]) { chunks.append(chunk) }
                wordIndex += min(
                    MIDI1UMPCodec.wordCount(forFirstWord: word),
                    packetWordCount - wordIndex
                )
            }
            packet = UnsafePointer(MIDIEventPacketNext(packet))
        }
        return (result, chunks)
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreMIDIServiceError.operation(name: operation, status: status)
        }
    }
}
