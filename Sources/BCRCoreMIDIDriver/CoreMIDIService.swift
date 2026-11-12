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
}

public extension MIDIService {
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

    public init(selection: MIDIEndpointSelection = .init()) { self.selection = selection }

    public func selectEndpoints(_ selection: MIDIEndpointSelection) {
        self.selection = selection
        transport?.selectEndpoints(selection)
    }

    public func start() throws {
        guard transport == nil else { return }
        let transport = CoreMIDITransport(
            selection: selection,
            onMessages: { [weak self] messages in
                Task { @MainActor [weak self] in self?.receive(messages) }
            },
            onConnection: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    if self?.connection != snapshot, let id = self?.snapshotID { self?.finishSnapshot(
                        id,
                        result: .failure(HardwareSnapshotError.invalid)
                    ) }
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
        try transport.send(message)
    }

    public func readSnapshot(expected: Set<MIDIControlID>) async throws -> [MIDIVoiceMessage] {
        guard snapshotID == nil, connection.isConnected, !expected.isEmpty,
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
                do { try transport.sendBytes(Self.snapshotRequest) }
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

    private func receive(_ messages: [MIDIVoiceMessage]) {
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
}

/// Owns CoreMIDI objects on a private serial queue. The receive callback only copies/decodes
/// packet words and immediately hands value types to the application.
private final class CoreMIDITransport: @unchecked Sendable {
    typealias MessageHandler = @Sendable ([MIDIVoiceMessage]) -> Void
    typealias ConnectionHandler = @Sendable (MIDIConnectionSnapshot) -> Void

    private let messageHandler: MessageHandler
    private let connectionHandler: ConnectionHandler
    private let managementQueue = DispatchQueue(label: "dev.bcragentconsole.coremidi")

    private var client: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var connectedSources: [MIDIEndpointRef] = []
    private var destination: MIDIEndpointRef = 0
    private var isStarted = false
    private var selection: MIDIEndpointSelection

    init(
        selection: MIDIEndpointSelection,
        onMessages: @escaping MessageHandler,
        onConnection: @escaping ConnectionHandler
    ) {
        self.selection = selection
        messageHandler = onMessages
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
            ) { [weak self] eventList, _ in
                guard let self else {
                    return
                }
                let messages = Self.decode(eventList)
                if !messages.isEmpty {
                    self.messageHandler(messages)
                }
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

    public func send(_ message: MIDIVoiceMessage) throws {
        try message.validate()
        try sendBytes(message.midi1Bytes)
    }

    func sendBytes(_ data: [UInt8]) throws {
        try managementQueue.sync {
            guard isStarted, outputPort != 0, destination != 0 else {
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
            let status = MIDIPortConnectSource(inputPort, selectedSource.endpoint, nil)
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
        connectionHandler(snapshot)
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
    ) -> [MIDIVoiceMessage] {
        guard
            let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet),
            let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)
        else {
            return []
        }

        var result: [MIDIVoiceMessage] = []
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
                wordIndex += min(
                    MIDI1UMPCodec.wordCount(forFirstWord: word),
                    packetWordCount - wordIndex
                )
            }
            packet = UnsafePointer(MIDIEventPacketNext(packet))
        }
        return result
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreMIDIServiceError.operation(name: operation, status: status)
        }
    }
}
