import BCRAgentCore
import CoreMIDI
import Foundation

struct MIDIConnectionSnapshot: Equatable, Sendable {
    var sourceNames: [String] = []
    var destinationNames: [String] = []
    var connectedSource: String?
    var connectedDestination: String?
    var lastError: String?

    var isConnected: Bool {
        connectedSource != nil && connectedDestination != nil
    }
}

enum CoreMIDIServiceError: Error, LocalizedError {
    case operation(name: String, status: OSStatus)
    case outputUnavailable
    case eventListFull

    var errorDescription: String? {
        switch self {
        case let .operation(name, status):
            "\(name) 失败（OSStatus \(status)）"
        case .outputUnavailable:
            "BCR2000 输出端口尚未连接"
        case .eventListFull:
            "无法构造 MIDI Event List"
        }
    }
}

/// Owns CoreMIDI objects on a private serial queue. The receive callback only copies/decodes
/// packet words and immediately hands value types to the application.
final class CoreMIDIService: @unchecked Sendable {
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

    init(
        onMessages: @escaping MessageHandler,
        onConnection: @escaping ConnectionHandler
    ) {
        messageHandler = onMessages
        connectionHandler = onConnection
    }

    deinit {
        stop()
    }

    func start() throws {
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
            try Self.check(clientStatus, operation: "创建 MIDI Client")
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
                try Self.check(inputStatus, operation: "创建 MIDI Input Port")
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
                try Self.check(outputStatus, operation: "创建 MIDI Output Port")
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

    func send(_ message: MIDIVoiceMessage) throws {
        try managementQueue.sync {
            guard isStarted, outputPort != 0, destination != 0 else {
                throw CoreMIDIServiceError.outputUnavailable
            }

            var packetList = MIDIPacketList()
            let packet = MIDIPacketListInit(&packetList)
            let addedPacket = message.midi1Bytes.withUnsafeBufferPointer { bytes -> UnsafeMutablePointer<MIDIPacket>? in
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
            try Self.check(status, operation: "发送 MIDI Feedback")
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

        let bcrSources = sources.filter { Self.isBCR2000($0.name) }
        let bcrDestinations = destinations.filter { Self.isBCR2000($0.name) }
        let selectedSource = Self.preferredPortOne(in: bcrSources)
        let selectedDestination = Self.preferredPortOne(in: bcrDestinations)

        var lastError: String?
        if let selectedSource {
            let status = MIDIPortConnectSource(inputPort, selectedSource.endpoint, nil)
            if status == noErr {
                connectedSources = [selectedSource.endpoint]
            } else {
                lastError = CoreMIDIServiceError.operation(
                    name: "连接 \(selectedSource.name)",
                    status: status
                ).localizedDescription
            }
        }

        if let selectedDestination {
            destination = selectedDestination.endpoint
        }

        connectionHandler(
            MIDIConnectionSnapshot(
                sourceNames: bcrSources.map(\.name),
                destinationNames: bcrDestinations.map(\.name),
                connectedSource: connectedSources.isEmpty ? nil : selectedSource?.name,
                connectedDestination: destination == 0 ? nil : selectedDestination?.name,
                lastError: lastError
            )
        )
    }

    private struct NamedEndpoint {
        let endpoint: MIDIEndpointRef
        let name: String
    }

    private static func endpoints(
        count: () -> Int,
        endpointAt: (Int) -> MIDIEndpointRef
    ) -> [NamedEndpoint] {
        (0..<count()).compactMap { index in
            let endpoint = endpointAt(index)
            guard endpoint != 0 else {
                return nil
            }
            return NamedEndpoint(
                endpoint: endpoint,
                name: endpointName(endpoint) ?? "未命名 MIDI 端点"
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

    private static func isBCR2000(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("BCR2000")
    }

    private static func preferredPortOne(in endpoints: [NamedEndpoint]) -> NamedEndpoint? {
        endpoints.first {
            $0.name.localizedCaseInsensitiveContains("Port 1")
        } ?? endpoints.first
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

        for _ in 0..<eventList.pointee.numPackets {
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
