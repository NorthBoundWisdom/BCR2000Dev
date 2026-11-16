import BCRFoundation
import BCRSurfaceDomain
import CoreMIDI
import Darwin
import Foundation

struct OwnedMIDIRef: Hashable, Sendable {
    enum Kind: String, Sendable { case client, source, destination, inputPort, outputPort }
    let raw: UInt32
    let kind: Kind
    let owner: UUID
}

enum OwnedVirtualError: Error, Equatable {
    case operation(String, Int32), ownership, disconnected, invalidMessage, invalidPeer, callbackOverflow
}

/// The only system operations available to this backend. There is no enumeration,
/// endpoint lookup, native-driver factory, SysEx or arbitrary raw MIDI interface.
protocol OwnedVirtualMIDIAPI: Sendable {
    func client(_ name: String, notify: @escaping @Sendable (UInt32) -> Void) throws -> UInt32
    func source(_ client: UInt32, _ name: String) throws -> UInt32
    func destination(_ client: UInt32, _ name: String, receive: @escaping @Sendable ([UInt32]) -> Void) throws -> UInt32
    func inputPort(_ client: UInt32, _ name: String,
                   receive: @escaping @Sendable ([UInt32], UInt, Double) -> Void) throws -> UInt32
    func outputPort(_ client: UInt32, _ name: String) throws -> UInt32
    func uniqueID(_ endpoint: UInt32) throws -> Int32
    func connect(_ port: UInt32, _ source: UInt32, generation: UInt) throws
    func disconnect(_ port: UInt32, _ source: UInt32) throws
    func publish(_ source: UInt32, message: MIDIVoiceMessage) throws
    func send(_ port: UInt32, _ destination: UInt32, message: MIDIVoiceMessage) throws
    func dispose(_ ref: OwnedMIDIRef) throws
}

struct OwnedCallPolicy: Sendable {
    static let allowed: Set<String> = ["create_client", "create_source", "create_destination", "create_input_port",
                                       "create_output_port", "read_owned_uid", "connect_owned_source",
                                       "disconnect_owned_source",
                                       "publish_owned_input", "send_owned_display", "dispose_owned"]
    func validate(_ operation: String, refs: [OwnedMIDIRef], owned: Set<OwnedMIDIRef>) throws {
        guard Self.allowed.contains(operation),
              refs.allSatisfy(owned.contains) else { throw OwnedVirtualError.ownership }
    }
}

struct OwnedVirtualInput: Sendable {
    let messages: [MIDIVoiceMessage]
    let endpoint: MIDIEndpointSource
    let receivedAt: Double
    let ticket: OwnedVirtualInputTicket
}

/// A callback occupies capacity until the MainActor consumes or rejects it.
/// Completion is idempotent, including weak-owner and cancellation release paths.
final class OwnedVirtualInputTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    init(_ completion: @escaping @Sendable () -> Void) { self.completion = completion }
    func finish() {
        lock.lock(); let action = completion; completion = nil; lock.unlock()
        action?()
    }

    deinit { finish() }
}

/// Serial ownership/call boundary used by both the real system and test API.
/// Every successful system invocation is recorded here, never inferred from names.
final class OwnedVirtualMIDIGraph: @unchecked Sendable {
    private let queue = DispatchQueue(label: "astro.owned-virtual-midi")
    private let api: any OwnedVirtualMIDIAPI
    private let owner = UUID()
    private let name = "AstroRehearsal-" + UUID().uuidString
    private var owned: Set<OwnedMIDIRef> = []
    private var creation: [OwnedMIDIRef] = []
    private var issued: [OwnedMIDIRef] = []
    private var counts: [String: Int] = [:]
    private var droppedCallRecords = 0
    private var refs: [OwnedMIDIRef.Kind: OwnedMIDIRef] = [:]
    private var generation: UInt = 0
    private var connected = false
    private var sourceID: Int32?
    private var destinationID: Int32?
    private var calls: [[String: JSONValue]] = []
    private var sinkReceipts: [[UInt8]] = []
    private var failures: [String] = []
    private var staleInputs = 0
    private var cleanupAttempted = false
    private let policy = OwnedCallPolicy()
    private let callbackLock = NSLock()
    private var callbacksInFlight = 0
    private var overflow = false
    var onInput: (@Sendable (OwnedVirtualInput) -> Void)?
    var onFault: (@Sendable (String, MIDIConnectionSnapshot) -> Void)?

    init(api: any OwnedVirtualMIDIAPI = SystemOwnedVirtualMIDIAPI()) { self.api = api }

    private func call<T>(_ operation: String, refs required: [OwnedMIDIRef] = [], _ body: () throws -> T) throws -> T {
        try policy.validate(operation, refs: required, owned: owned)
        counts[operation, default: 0] += 1
        if calls.count == 4096 { calls.removeFirst(); droppedCallRecords += 1 }
        calls.append([
            "generation": .number(Int(generation)),
            "operation": .string(operation),
            "refs": .array(required.map { .object([
                "kind": .string($0.kind.rawValue), "ref": .number(Int($0.raw)), "owner": .string($0.owner.uuidString)
            ]) }),
            "owned_virtual_rehearsal": .bool(true),
            "physical_evidence": .bool(false)
        ])
        return try body()
    }

    private func create(_ kind: OwnedMIDIRef.Kind, operation: String, parent: [OwnedMIDIRef] = [],
                        _ body: () throws -> UInt32) throws -> OwnedMIDIRef
    {
        let raw = try call(operation, refs: parent, body)
        guard raw != 0 else { throw OwnedVirtualError.ownership }
        let ref = OwnedMIDIRef(raw: raw, kind: kind, owner: owner)
        guard !owned.contains(ref) else { throw OwnedVirtualError.ownership }
        owned.insert(ref); creation.append(ref); issued.append(ref); refs[kind] = ref
        return ref
    }

    private func ref(_ kind: OwnedMIDIRef.Kind) throws -> OwnedMIDIRef {
        guard let value = refs[kind], value.owner == owner,
              owned.contains(value) else { throw OwnedVirtualError.ownership }
        return value
    }

    private func snapshot() -> MIDIConnectionSnapshot {
        var value = MIDIConnectionSnapshot()
        value.transportGeneration = generation
        if connected, let sourceID, let destinationID {
            value.connectedSourceID = sourceID; value.connectedDestinationID = destinationID
            value.connectedSource = name + ".input"; value.connectedDestination = name + ".display"
            value.sourceEndpoints = [.init(id: sourceID, name: value.connectedSource!, provenance: .localVirtual)]
            value.destinationEndpoints = [.init(
                id: destinationID,
                name: value.connectedDestination!,
                provenance: .localVirtual
            )]
            value.sourceNames = [value.connectedSource!]; value.destinationNames = [value.connectedDestination!]
        }
        value.lastError = failures.last
        return value
    }

    func start() async throws -> MIDIConnectionSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard self.creation.isEmpty else { throw OwnedVirtualError.ownership }
                    let client = try self
                        .create(.client, operation: "create_client") {
                            try self.api.client(self.name) { [weak self = self] object in self?.notification(object) }
                        }
                    let source = try self.create(.source, operation: "create_source", parent: [client]) {
                        try self.api.source(client.raw, self.name + ".input")
                    }
                    let destination = try self.create(.destination, operation: "create_destination", parent: [client]) {
                        try self.api.destination(client.raw, self.name + ".display") { [weak self = self] words in
                            self?.queue.async { [weak self] in
                                guard let self else { return }
                                if self.sinkReceipts
                                    .count >=
                                    4096 { self.failures.append("display_receipt_capacity_exhausted"); return }
                                self.sinkReceipts += MIDI1UMPCodec.decode(words: words).map(\.midi1Bytes)
                            }
                        }
                    }
                    _ = try self.create(.inputPort, operation: "create_input_port", parent: [client]) {
                        try self.api
                            .inputPort(client.raw,
                                       self.name + ".input-port")
                            { [weak self = self] words, generation, receivedAt in
                                self?.enqueue(words, generation: generation, receivedAt: receivedAt)
                            }
                    }
                    _ = try self.create(.outputPort, operation: "create_output_port", parent: [client]) {
                        try self.api.outputPort(client.raw, self.name + ".output-port")
                    }
                    self.sourceID = try self
                        .call("read_owned_uid", refs: [source]) { try self.api.uniqueID(source.raw) }
                    self.destinationID = try self
                        .call("read_owned_uid", refs: [destination]) { try self.api.uniqueID(destination.raw) }
                    guard self.sourceID != 0, self.destinationID != 0 else { throw OwnedVirtualError.ownership }
                    try self.connect()
                    continuation.resume(returning: self.snapshot())
                } catch {
                    self.failures.append(String(describing: error))
                    self.cleanup()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func connect() throws {
        let source = try ref(.source), port = try ref(.inputPort)
        // Only returned owned refs are revalidated; no lookup by name or ID is possible.
        let current = try call("read_owned_uid", refs: [source]) { try api.uniqueID(source.raw) }
        let destination = try ref(.destination)
        let currentDestination = try call("read_owned_uid", refs: [destination]) { try api.uniqueID(destination.raw) }
        guard current == sourceID, currentDestination == destinationID else { throw OwnedVirtualError.ownership }
        generation &+= 1
        try call("connect_owned_source", refs: [port, source]) { try api.connect(
            port.raw,
            source.raw,
            generation: generation
        ) }
        connected = true
        callbackLock.lock(); overflow = false; callbackLock.unlock()
    }

    func disconnect() throws -> MIDIConnectionSnapshot {
        try queue.sync {
            if connected {
                let source = try ref(.source), port = try ref(.inputPort)
                try call("disconnect_owned_source", refs: [port, source]) { try api.disconnect(port.raw, source.raw) }
            }
            connected = false; generation &+= 1
            return snapshot()
        }
    }

    func reconnect() throws -> MIDIConnectionSnapshot {
        try queue.sync {
            guard !connected else { return snapshot() }
            try connect(); return snapshot()
        }
    }

    func publish(_ message: MIDIVoiceMessage) throws {
        try queue.sync {
            guard connected else { throw OwnedVirtualError.disconnected }
            let source = try ref(.source)
            let uid = try call("read_owned_uid", refs: [source]) { try api.uniqueID(source.raw) }
            guard uid == sourceID else { throw OwnedVirtualError.ownership }
            try call("publish_owned_input", refs: [source]) { try api.publish(source.raw, message: message) }
        }
    }

    func send(_ message: MIDIVoiceMessage, destination override: OwnedMIDIRef? = nil) throws {
        try queue.sync {
            guard connected else { throw OwnedVirtualError.disconnected }
            let port = try ref(.outputPort), destination = try ref(.destination)
            guard override == nil || override == destination else { throw OwnedVirtualError.ownership }
            let uid = try call("read_owned_uid", refs: [destination]) { try api.uniqueID(destination.raw) }
            guard uid == destinationID else { throw OwnedVirtualError.ownership }
            try call("send_owned_display", refs: [port, destination]) { try api.send(
                port.raw,
                destination.raw,
                message: message
            ) }
        }
    }

    private func notification(_ object: UInt32) {
        queue.async {
            guard self.connected,
                  self.owned.contains(where: { $0.raw == object && ($0.kind == .source || $0.kind == .destination) })
            else { return }
            do {
                let source = try self.ref(.source), destination = try self.ref(.destination)
                let inputID = try self.call("read_owned_uid", refs: [source]) { try self.api.uniqueID(source.raw) }
                let outputID = try self
                    .call("read_owned_uid", refs: [destination]) { try self.api.uniqueID(destination.raw) }
                guard inputID == self.sourceID,
                      outputID == self.destinationID else { throw OwnedVirtualError.ownership }
            } catch { self.revoke("owned_endpoint_invalid") }
        }
    }

    func invalidate(_ reason: String) -> MIDIConnectionSnapshot {
        queue.sync { invalidateOnQueue(reason) }
    }

    private func invalidateOnQueue(_ reason: String) -> MIDIConnectionSnapshot {
        if connected, let source = refs[.source], let port = refs[.inputPort] {
            do {
                try call("disconnect_owned_source", refs: [port, source]) {
                    try api.disconnect(port.raw, source.raw)
                }
            } catch { failures.append("owned_fault_disconnect_failed") }
        }
        connected = false; generation &+= 1; failures.append(reason)
        return snapshot()
    }

    private func revoke(_ reason: String) {
        let value = invalidateOnQueue(reason)
        onFault?(reason, value)
    }

    func isCurrent(_ snapshot: MIDIConnectionSnapshot) -> Bool {
        queue.sync { snapshot.transportGeneration == generation }
    }

    func admits(_ endpoint: MIDIEndpointSource) -> Bool {
        queue.sync {
            callbackLock.lock(); let withinCapacity = !overflow; callbackLock.unlock()
            return withinCapacity && connected && endpoint.connectionGeneration == UInt64(generation) &&
                sourceID.map(String.init) == endpoint.endpointID && endpoint.provenance == .localVirtual
        }
    }

    private func completeCallback() {
        callbackLock.lock(); defer { callbackLock.unlock() }
        precondition(callbacksInFlight > 0, "Owned callback ticket released without capacity")
        callbacksInFlight -= 1
    }

    private func enqueue(_ words: [UInt32], generation tagged: UInt, receivedAt: Double) {
        callbackLock.lock()
        guard !overflow, callbacksInFlight < 256, words.count <= 256 else {
            let first = !overflow; overflow = true; callbackLock.unlock()
            if first { queue.async { self.revoke("owned_callback_overflow") } }
            return
        }
        callbacksInFlight += 1; callbackLock.unlock()
        let ticket = OwnedVirtualInputTicket { [weak self] in self?.completeCallback() }
        queue.async {
            var delivered = false
            defer { if !delivered { ticket.finish() } }
            guard self.connected, tagged == self.generation,
                  let id = self.sourceID else { self.staleInputs += 1; return }
            let messages = MIDI1UMPCodec.decode(words: words)
            guard !messages.isEmpty else { self.revoke("owned_decode_rejected"); return }
            guard let onInput = self.onInput else { return }
            delivered = true
            onInput(.init(messages: messages,
                          endpoint: .init(
                              endpointID: String(id),
                              connectionGeneration: UInt64(tagged),
                              provenance: .localVirtual
                          ),
                          receivedAt: receivedAt, ticket: ticket))
        }
    }

    private func cleanup() {
        guard !cleanupAttempted else { return }
        cleanupAttempted = true
        let wasConnected = connected
        connected = false; generation &+= 1
        if wasConnected, let port = refs[.inputPort], let source = refs[.source] {
            do { try call("disconnect_owned_source", refs: [port, source]) { try api.disconnect(port.raw, source.raw) }
            } catch { failures.append("owned_disconnect_failed") }
        }
        for item in creation.reversed() {
            do {
                try call("dispose_owned", refs: [item]) { try api.dispose(item) }
                owned.remove(item)
            } catch { failures.append("owned_dispose_failed:" + item.kind.rawValue) }
        }
        creation = creation.filter(owned.contains)
        refs = refs.filter { owned.contains($0.value) }
    }

    func stop() -> [String] { queue.sync { cleanup(); return failures } }
    func audit() -> JSONValue {
        queue
            .sync {
                callbackLock.lock(); let pending = callbacksInFlight; callbackLock.unlock()
                return .object([
                    "artifact": .string("owned-virtual-rehearsal-audit"),
                    "owned_virtual_rehearsal": .bool(true),
                    "physical_evidence": .bool(false),
                    "hardware_qualified": .bool(false),
                    "calls": .array(calls.map(JSONValue.object)),
                    "call_counts": .object(counts.mapValues(JSONValue.number)),
                    "created_refs": .array(issued.map { .object([
                        "kind": .string($0.kind.rawValue),
                        "ref": .number(Int($0.raw)),
                        "owner": .string($0.owner.uuidString)
                    ]) }),
                    "unconfirmed_cleanup_refs": .array(owned.map { .object([
                        "kind": .string($0.kind.rawValue),
                        "ref": .number(Int($0.raw))
                    ]) }),
                    "dropped_call_records": .number(droppedCallRecords),
                    "pending_input_tickets": .number(pending),
                    "display_receipts": .array(sinkReceipts.map { .array($0.map { .number(Int($0)) }) }),
                    "stale_inputs": .number(staleInputs),
                    "failures": .array(failures.map(JSONValue.string))
                ])
            }
    }
}
