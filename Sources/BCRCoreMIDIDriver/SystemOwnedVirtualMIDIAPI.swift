import BCRSurfaceDomain
import CoreMIDI
import Darwin
import Foundation

/// Raw operations behind the graph's production ownership policy. No discovery API exists here.
struct SystemOwnedVirtualMIDIAPI: OwnedVirtualMIDIAPI {
    private func check(_ status: OSStatus, _ name: String) throws {
        guard status == noErr else { throw OwnedVirtualError.operation(name, status) }
    }

    func client(_ name: String, notify: @escaping @Sendable (UInt32) -> Void) throws -> UInt32 {
        var ref: MIDIClientRef = 0
        try check(MIDIClientCreateWithBlock(name as CFString, &ref) { notification in
            if notification.pointee.messageID == .msgObjectRemoved {
                let value = UnsafeRawPointer(notification).assumingMemoryBound(to: MIDIObjectAddRemoveNotification.self)
                    .pointee
                notify(value.child)
            } else if notification.pointee.messageID == .msgPropertyChanged {
                let value = UnsafeRawPointer(notification)
                    .assumingMemoryBound(to: MIDIObjectPropertyChangeNotification.self).pointee
                notify(value.object)
            }
        }, "create_client")
        return ref
    }

    func source(_ client: UInt32, _ name: String) throws -> UInt32 {
        var ref: MIDIEndpointRef = 0
        try check(MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &ref), "create_source")
        return ref
    }

    func destination(_ client: UInt32, _ name: String,
                     receive: @escaping @Sendable ([UInt32]) -> Void) throws -> UInt32
    {
        var ref: MIDIEndpointRef = 0
        try check(MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &ref) { events, _ in
            receive(Self.words(events))
        }, "create_destination")
        return ref
    }

    func inputPort(_ client: UInt32, _ name: String,
                   receive: @escaping @Sendable ([UInt32], UInt, Double) -> Void) throws -> UInt32
    {
        var ref: MIDIPortRef = 0
        try check(MIDIInputPortCreateWithProtocol(client, name as CFString, ._1_0, &ref) { events, context in
            let receivedAt = ProcessInfo.processInfo.systemUptime
            receive(Self.words(events), context.map { UInt(bitPattern: $0) } ?? 0, receivedAt)
        }, "create_input_port")
        return ref
    }

    func outputPort(_ client: UInt32, _ name: String) throws -> UInt32 {
        var ref: MIDIPortRef = 0
        try check(MIDIOutputPortCreate(client, name as CFString, &ref), "create_output_port")
        return ref
    }

    func uniqueID(_ endpoint: UInt32) throws -> Int32 {
        var value: Int32 = 0
        try check(MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &value), "read_owned_uid")
        return value
    }

    func connect(_ port: UInt32, _ source: UInt32, generation: UInt) throws {
        try check(
            MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: generation)),
            "connect_owned_source"
        )
    }

    func disconnect(_ port: UInt32, _ source: UInt32) throws {
        try check(MIDIPortDisconnectSource(port, source), "disconnect_owned_source")
    }

    private func event(_ message: MIDIVoiceMessage, operation: String,
                       _ body: (UnsafePointer<MIDIEventList>) -> OSStatus) throws
    {
        // SysEx, NRPN multiword and Program Change cannot be encoded by this typed path.
        var word = try MIDI1UMPCodec.encode(message)
        var list = MIDIEventList()
        try withUnsafeMutablePointer(to: &list) { pointer in
            let packet = MIDIEventListInit(pointer, ._1_0)
            _ = withUnsafePointer(to: &word) { words in
                MIDIEventListAdd(pointer, MemoryLayout<MIDIEventList>.size, packet, mach_absolute_time(), 1, words)
            }
            try check(body(UnsafePointer(pointer)), operation)
        }
    }

    func publish(_ source: UInt32, message: MIDIVoiceMessage) throws {
        try event(message, operation: "publish_owned_input") { MIDIReceivedEventList(source, $0) }
    }

    func send(_ port: UInt32, _ destination: UInt32, message: MIDIVoiceMessage) throws {
        try event(message, operation: "send_owned_display") { MIDISendEventList(port, destination, $0) }
    }

    func dispose(_ ref: OwnedMIDIRef) throws {
        let status: OSStatus
        switch ref.kind {
        case .client: status = MIDIClientDispose(ref.raw)
        case .source, .destination: status = MIDIEndpointDispose(ref.raw)
        case .inputPort, .outputPort: status = MIDIPortDispose(ref.raw)
        }
        try check(status, "dispose_owned_" + ref.kind.rawValue)
    }

    private static func words(_ events: UnsafePointer<MIDIEventList>) -> [UInt32] {
        guard events.pointee.protocol == ._1_0, events.pointee.numPackets <= 256,
              let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet),
              let wordOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)
        else {
            return Array(repeating: 0, count: 257) // Explicit overflow/fault signal to the bounded graph callback.
        }
        var result: [UInt32] = []
        var packet = UnsafeRawPointer(events).advanced(by: packetOffset).assumingMemoryBound(to: MIDIEventPacket.self)
        for _ in 0 ..< events.pointee.numPackets {
            let count = Int(packet.pointee.wordCount)
            guard count <= 256, result.count + count <= 256 else { return Array(repeating: 0, count: 257) }
            let words = UnsafeRawPointer(packet).advanced(by: wordOffset).assumingMemoryBound(to: UInt32.self)
            result += UnsafeBufferPointer(start: words, count: count)
            packet = UnsafePointer(MIDIEventPacketNext(packet))
        }
        return result
    }
}
