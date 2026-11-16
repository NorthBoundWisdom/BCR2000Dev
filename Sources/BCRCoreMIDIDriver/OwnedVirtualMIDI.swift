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

/// Closed own-reference API: no enumeration, lookup, native factory or raw output operation.
protocol OwnedVirtualMIDIAPI: Sendable {
    func client(_ name: String, notify: @escaping @Sendable (UInt32) -> Void) throws -> UInt32
    func source(_ client: UInt32, _ name: String) throws -> UInt32
    func destination(_ client: UInt32, _ name: String,
                     receive: @escaping @Sendable (OwnedVirtualWire) -> Void) throws -> UInt32
    func inputPort(_ client: UInt32, _ name: String,
                   receive: @escaping @Sendable (OwnedVirtualWire, UInt, Double) -> Void) throws -> UInt32
    func outputPort(_ client: UInt32, _ name: String) throws -> UInt32
    func uniqueID(_ endpoint: UInt32) throws -> Int32
    func connect(_ port: UInt32, _ source: UInt32, generation: UInt) throws
    func disconnect(_ port: UInt32, _ source: UInt32) throws
    func publish(_ source: UInt32, message: MIDIVoiceMessage) throws
    func send(_ port: UInt32, _ destination: UInt32, message: MIDIVoiceMessage, timestamp: UInt64) throws
    func dispose(_ ref: OwnedMIDIRef) throws
}

struct OwnedCallPolicy: Sendable {
    static let allowed: Set<String> = ["create_client", "create_source", "create_destination", "create_input_port",
                                       "create_output_port", "read_owned_uid", "connect_owned_source",
                                       "disconnect_owned_source", "publish_owned_input", "send_owned_display",
                                       "dispose_owned"]
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

final class OwnedVirtualInputTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable () -> Void)?
    init(_ completion: @escaping @Sendable () -> Void) { self.completion = completion }
    func finish() {
        lock.lock(); let action = completion; completion = nil; lock.unlock(); action?()
    }

    deinit { finish() }
}

final class OwnedVirtualMIDIGraph: @unchecked Sendable {
    private struct PendingReceipt { let generation: UInt; let word: UInt32 }
    private struct Receipt {
        let wire: OwnedVirtualWire
        let normalized: [[UInt8]]
        let sentGenerations: [UInt?]
        let callbackGeneration: UInt
        let destination: OwnedMIDIRef
    }

    private let queue = DispatchQueue(label: "astro.owned-virtual-midi")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let api: any OwnedVirtualMIDIAPI
    private let owner = UUID(), name = "AstroRehearsal-" + UUID().uuidString
    private var owned: Set<OwnedMIDIRef> = [], creation: [OwnedMIDIRef] = [], issued: [OwnedMIDIRef] = []
    private var refs: [OwnedMIDIRef.Kind: OwnedMIDIRef] = [:]
    private var counts: [String: Int] = [:], calls: [[String: JSONValue]] = []
    private var failures: [String] = []
    private var droppedCallRecords = 0, droppedFailures = 0, receiptWordCount = 0
    private var receipts: [Receipt] = [], pendingReceipts: [UInt64: PendingReceipt] = [:]
    private var lastReceiptStamp: UInt64 = 0
    private var generation: UInt = 0
    private var connected = false, stopped = false, faulted = false, connectionUncertain = false
    private var cleanupAttempted = false, cleanupInProgress = false
    private var sourceID: Int32?, destinationID: Int32?
    private let policy = OwnedCallPolicy(), ingress = OwnedIngressControl()
    private let inputBudget = OwnedIngressBudget(
        tasks: 256,
        units: 65536,
        bytes: 262144,
        byteAccounting: "raw UMP bytes; one bounded timestamp and decoded value per word"
    )
    private let receiptBudget = OwnedIngressBudget(
        tasks: 64,
        units: 4096,
        bytes: 16384,
        byteAccounting: "raw UMP bytes; one bounded timestamp and decoded value per word"
    )
    var onInput: (@Sendable (OwnedVirtualInput) -> Void)?
    var onFault: (@Sendable (String, MIDIConnectionSnapshot) -> Void)?

    init(api: any OwnedVirtualMIDIAPI = SystemOwnedVirtualMIDIAPI()) {
        self.api = api; queue.setSpecific(key: queueKey, value: 1)
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == 1 { return try body() }
        return try queue.sync(execute: body)
    }

    private func recordFailure(_ reason: String) {
        let reason = String(reason.prefix(256))
        guard failures.last != reason else { return }
        if failures.count == 64 { failures.removeFirst(); droppedFailures = min(droppedFailures, Int.max - 1) + 1 }
        failures.append(reason)
    }

    private func publishIngress(reopen: Bool = false) {
        ingress.publish(generation: generation, connected: connected,
                        endpoints: Set(refs.values.filter { $0.kind == .source || $0.kind == .destination }.map(\.raw)),
                        reopen: reopen)
    }

    private func call<T>(_ operation: String, refs required: [OwnedMIDIRef] = [], _ body: () throws -> T) throws -> T {
        try policy.validate(operation, refs: required, owned: owned)
        counts[operation] = min(counts[operation, default: 0], Int.max - 1) + 1
        if calls.count == 4096 { calls.removeFirst(); droppedCallRecords = min(droppedCallRecords, Int.max - 1) + 1 }
        calls.append(["generation": .number(Int(generation)), "operation": .string(operation),
                      "refs": .array(required.map { .object([
                          "kind": .string($0.kind.rawValue),
                          "ref": .number(Int($0.raw)),
                          "owner": .string($0.owner.uuidString)
                      ]) }),
                      "owned_virtual_rehearsal": .bool(true), "physical_evidence": .bool(false)])
        return try body()
    }

    private func create(_ kind: OwnedMIDIRef.Kind, operation: String, parent: [OwnedMIDIRef] = [],
                        _ body: () throws -> UInt32) throws -> OwnedMIDIRef
    {
        guard !stopped else { throw OwnedVirtualError.disconnected }
        let raw = try call(operation, refs: parent, body)
        guard raw != 0 else { throw OwnedVirtualError.ownership }
        let value = OwnedMIDIRef(raw: raw, kind: kind, owner: owner)
        guard !owned.contains(value) else { throw OwnedVirtualError.ownership }
        owned.insert(value); creation.append(value); issued.append(value); refs[kind] = value
        publishIngress()
        return value
    }

    private func ref(_ kind: OwnedMIDIRef.Kind) throws -> OwnedMIDIRef {
        guard let value = refs[kind], value.owner == owner,
              owned.contains(value) else { throw OwnedVirtualError.ownership }
        return value
    }

    private func snapshot() -> MIDIConnectionSnapshot {
        var value = MIDIConnectionSnapshot(); value.transportGeneration = generation
        if connected, !stopped, let sourceID, let destinationID {
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
        value.lastError = failures.last; return value
    }

    var currentSnapshot: MIDIConnectionSnapshot { sync { snapshot() } }
    var peerGeneration: UInt? { ingress.current() }
    var ingressAudit: JSONValue { ingress.audit }
    var receiptIngressAudit: JSONValue { receiptBudget.audit }
    func admitsPeer(_ tagged: UInt) -> Bool { ingress.admits(tagged, requireConnection: false) }

    func start() async throws -> MIDIConnectionSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !self.stopped, self.creation.isEmpty else { throw OwnedVirtualError.ownership }
                    let client = try self.create(.client, operation: "create_client") {
                        try self.api.client(self.name) { [weak self = self] object in self?.notification(object) }
                    }
                    let source = try self.create(.source, operation: "create_source", parent: [client]) {
                        try self.api.source(client.raw, self.name + ".input")
                    }
                    let destination = try self.create(.destination, operation: "create_destination", parent: [client]) {
                        try self.api
                            .destination(client.raw, self.name + ".display") { [weak self = self] wire in
                                self?.receipt(wire)
                            }
                    }
                    _ = try self.create(.inputPort, operation: "create_input_port", parent: [client]) {
                        try self.api
                            .inputPort(client.raw, self.name + ".input-port") { [weak self = self] wire, tagged, at in
                                self?.enqueue(wire, generation: tagged, receivedAt: at)
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
                    try self.connect(); continuation.resume(returning: self.snapshot())
                } catch {
                    self.recordFailure(String(describing: error)); self.cleanup(); continuation.resume(throwing: error)
                }
            }
        }
    }

    private func connect() throws {
        guard !stopped, !connectionUncertain else { throw OwnedVirtualError.disconnected }
        do {
            let source = try ref(.source), destination = try ref(.destination), port = try ref(.inputPort)
            let inputID = try call("read_owned_uid", refs: [source]) { try api.uniqueID(source.raw) }
            let outputID = try call("read_owned_uid", refs: [destination]) { try api.uniqueID(destination.raw) }
            guard inputID == sourceID, outputID == destinationID else { throw OwnedVirtualError.ownership }
            generation &+= 1; let attempt = generation
            connectionUncertain = true // A throwing connect cannot prove that no connection was made.
            try call("connect_owned_source", refs: [port, source]) { try api.connect(
                port.raw,
                source.raw,
                generation: attempt
            ) }
            guard !stopped, generation == attempt else { throw OwnedVirtualError.disconnected }
            connectionUncertain = false; connected = true; faulted = false
            inputBudget.reopen(); receiptBudget.reopen(); publishIngress(reopen: true)
        } catch {
            connectionUncertain = true; revoke("owned_connect_failed"); throw error
        }
    }

    /// Logical revocation precedes IO. An uncertain disconnect is never retried by fault or cleanup.
    private func detach() throws {
        let wasConnected = connected
        connected = false; generation &+= 1; publishIngress()
        guard wasConnected else { return }
        connectionUncertain = true
        let source = try ref(.source), port = try ref(.inputPort)
        try call("disconnect_owned_source", refs: [port, source]) { try api.disconnect(port.raw, source.raw) }
        connectionUncertain = false
    }

    func disconnect() throws -> MIDIConnectionSnapshot {
        try sync {
            guard !stopped else { throw OwnedVirtualError.disconnected }
            do { try detach(); return snapshot() }
            catch { recordFailure("owned_disconnect_failed"); faulted = true; _ = ingress.seal(); throw error }
        }
    }

    func reconnect() throws -> MIDIConnectionSnapshot {
        try sync {
            guard !stopped, !connectionUncertain else { throw OwnedVirtualError.disconnected }
            guard !connected else { return snapshot() }
            try connect(); return snapshot()
        }
    }

    func publish(_ message: MIDIVoiceMessage) throws {
        try sync {
            guard !stopped, connected, ingress.admits(generation) else { throw OwnedVirtualError.disconnected }
            do {
                let source = try ref(.source)
                let uid = try call("read_owned_uid", refs: [source]) { try api.uniqueID(source.raw) }
                guard uid == sourceID else { throw OwnedVirtualError.ownership }
                guard !stopped, connected, ingress.admits(generation) else { throw OwnedVirtualError.disconnected }
                try call("publish_owned_input", refs: [source]) { try api.publish(source.raw, message: message) }
            } catch {
                if ingress
                    .current(requireConnection: true) != nil { revoke("owned_input_publish_failed") }; throw error
            }
        }
    }

    func send(_ message: MIDIVoiceMessage, destination override: OwnedMIDIRef? = nil) throws {
        try sync {
            guard !stopped, connected, ingress.admits(generation) else { throw OwnedVirtualError.disconnected }
            let destination = try ref(.destination), port = try ref(.outputPort)
            guard override == nil || override == destination else { throw OwnedVirtualError.ownership }
            do {
                let uid = try call("read_owned_uid", refs: [destination]) { try api.uniqueID(destination.raw) }
                guard uid == destinationID else { throw OwnedVirtualError.ownership }
                guard !stopped, connected, ingress.admits(generation) else { throw OwnedVirtualError.disconnected }
                guard pendingReceipts.count < 4096 else { throw OwnedVirtualError.callbackOverflow }
                let timestamp = max(mach_absolute_time(), lastReceiptStamp &+ 1); lastReceiptStamp = timestamp
                pendingReceipts[timestamp] = .init(generation: generation, word: try MIDI1UMPCodec.encode(message))
                try call("send_owned_display", refs: [port, destination]) {
                    try api.send(port.raw, destination.raw, message: message, timestamp: timestamp)
                }
            } catch {
                if ingress
                    .current(requireConnection: true) != nil { revoke("owned_display_transport_failed") }; throw error
            }
        }
    }

    private func notification(_ object: UInt32) {
        guard let tagged = ingress.notify(object) else { return }
        scheduleNotification(tagged)
    }

    private func scheduleNotification(_ tagged: UInt) {
        queue.async {
            if !self.stopped, self.ingress.admits(tagged, requireConnection: false) {
                do {
                    let source = try self.ref(.source), destination = try self.ref(.destination)
                    let inputID = try self.call("read_owned_uid", refs: [source]) { try self.api.uniqueID(source.raw) }
                    let outputID = try self
                        .call("read_owned_uid", refs: [destination]) { try self.api.uniqueID(destination.raw) }
                    guard inputID == self.sourceID,
                          outputID == self.destinationID else { throw OwnedVirtualError.ownership }
                } catch { self.connectionUncertain = true; self.revoke("owned_endpoint_invalid") }
            }
            if let next = self.ingress.finishNotification() { self.scheduleNotification(next) }
        }
    }

    /// Thread-safe callback rejection. Only the first rejection reserves a fault task.
    func requestFault(_ reason: String) {
        guard let tagged = ingress.seal() else { return }
        queue.async { if !self.stopped, self.generation == tagged { self.revoke(reason) } }
    }

    func invalidate(_ reason: String) -> MIDIConnectionSnapshot {
        sync { revoke(reason); return snapshot() }
    }

    private func revoke(_ reason: String) {
        guard !stopped, !faulted else { return }
        faulted = true; _ = ingress.seal()
        do { try detach() } catch { recordFailure("owned_fault_disconnect_failed") }
        recordFailure(reason); onFault?(reason, snapshot())
    }

    func isCurrent(_ value: MIDIConnectionSnapshot)
        -> Bool { sync { !stopped && value.transportGeneration == generation } }
    func admits(_ endpoint: MIDIEndpointSource) -> Bool {
        let tagged = endpoint.connectionGeneration
        guard tagged <= UInt64(UInt.max), ingress.admits(UInt(tagged)) else { return false }
        return sync {
            !stopped && connected && tagged == UInt64(generation) && sourceID.map(String.init) == endpoint
                .endpointID && endpoint.provenance == .localVirtual
        }
    }

    private func enqueue(_ wire: OwnedVirtualWire, generation tagged: UInt, receivedAt: Double) {
        guard ingress.admits(tagged) else { return }
        guard wire.words.count <= 256 else { requestFault("owned_callback_overflow"); return }
        let messages: [MIDIVoiceMessage]
        do { messages = try wire.decoded() } catch { requestFault("owned_decode_rejected"); return }
        guard let ticket = inputBudget.reserve(units: wire.words.count, bytes: wire.words.count * 4) else {
            requestFault("owned_callback_overflow"); return
        }
        queue.async {
            var delivered = false
            defer { if !delivered { ticket.finish() } }
            guard self.ingress.admits(tagged), !self.stopped, self.connected, tagged == self.generation,
                  let id = self.sourceID, let onInput = self.onInput else { return }
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

    private func receipt(_ wire: OwnedVirtualWire) {
        guard let tagged = ingress.current() else { return }
        guard wire.words.count <= 256 else { requestFault("owned_receipt_overflow"); return }
        let normalized: [[UInt8]]
        do { normalized = try wire.decoded().map(\.midi1Bytes) } catch {
            requestFault("owned_receipt_decode_rejected"); return
        }
        guard let ticket = receiptBudget.reserve(units: wire.words.count, bytes: wire.words.count * 4) else {
            requestFault("owned_receipt_overflow"); return
        }
        queue.async {
            defer { ticket.finish() }
            guard !self.stopped else { return }
            guard self.receiptWordCount + wire.words.count <= 4096
            else { self.revoke("owned_receipt_capacity_exhausted"); return }
            let sent = zip(wire.words, wire.timestamps).map { word, stamp -> UInt? in
                guard let pending = self.pendingReceipts[stamp], pending.word == word else { return nil }
                self.pendingReceipts.removeValue(forKey: stamp); return pending.generation
            }
            guard let destination = self.refs[.destination], self.owned.contains(destination) else { return }
            self.receipts.append(.init(
                wire: wire,
                normalized: normalized,
                sentGenerations: sent,
                callbackGeneration: tagged,
                destination: destination
            ))
            self.receiptWordCount += wire.words.count
        }
    }

    private func cleanup() {
        guard !cleanupAttempted else { return }
        cleanupAttempted = true; cleanupInProgress = true
        defer { cleanupInProgress = false }
        stopped = true; ingress.stop(); inputBudget.close(); receiptBudget.close()
        do { try detach() } catch { recordFailure("owned_disconnect_failed") }
        for value in creation.reversed() {
            do { try call("dispose_owned", refs: [value]) { try api.dispose(value) }; owned.remove(value) }
            catch { recordFailure("owned_dispose_failed:" + value.kind.rawValue) }
        }
        creation = creation.filter(owned.contains); refs = refs.filter { owned.contains($0.value) }
    }

    func stop() -> [String] { sync {
        if cleanupInProgress { return ["owned_cleanup_in_progress"] }
        cleanup(); return failures
    } }
    func audit() -> JSONValue {
        sync {
            let input = inputBudget.audit
            return .object([
                "artifact": .string("owned-virtual-rehearsal-audit"), "owned_virtual_rehearsal": .bool(true),
                "physical_evidence": .bool(false), "hardware_qualified": .bool(false),
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
                "dropped_failure_records": .number(droppedFailures),
                "pending_input_tickets": input.value(for: "pending_tasks") ?? .null,
                "input_ingress": input, "receipt_ingress": receiptBudget.audit, "callback_control": ingress.audit,
                "display_receipts": .array(receipts.flatMap(\.normalized).map { .array($0.map { .number(Int($0)) }) }),
                "display_receipts_format": .string(
                    "normalized MIDI1 view; original UMP words and timestamps are separate"
                ),
                "display_receipt_records": .array(receipts.map { row in .object([
                    "destination_ref": .number(Int(row.destination.raw)),
                    "owner": .string(row.destination.owner.uuidString),
                    "provenance": .string("localVirtual"),
                    "raw_ump_words": .array(row.wire.words.map { .number(Int($0)) }),
                    "raw_timestamps": .array(row.wire.timestamps.map { .string(String($0)) }),
                    "normalized_midi1_bytes": .array(row.normalized.map { .array($0.map { .number(Int($0)) }) }),
                    "send_generations": .array(row.sentGenerations.map { $0.map { .number(Int($0)) } ?? .null }),
                    "callback_generation": .number(Int(row.callbackGeneration)),
                    "current_scope": .array(row.sentGenerations
                        .map { .bool(!stopped && connected && $0 == generation && row.callbackGeneration == generation)
                        })
                ]) }),
                "pending_receipt_attributions": .number(pendingReceipts.count),
                "stale_inputs": ingress.audit.value(for: "stale_ingress") ?? .number(0),
                "failures": .array(failures.map(JSONValue.string)), "terminal_stopped": .bool(stopped),
                "connection_uncertain": .bool(connectionUncertain)
            ])
        }
    }
}
