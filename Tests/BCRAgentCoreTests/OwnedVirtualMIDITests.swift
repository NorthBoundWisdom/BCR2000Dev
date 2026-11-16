#if os(macOS) && !BCR_PORTABLE_BUILD
    @testable import BCRCoreMIDIDriver
    import BCRFoundation
    import BCRMCPAdapter
    import BCRProviderMCPAdapter
    import BCRSurfaceDomain
    import Foundation
    import Darwin
    import XCTest

    private final class OwnedAPIFake: OwnedVirtualMIDIAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var next: UInt32 = 100
        private var input: (@Sendable (OwnedVirtualWire, UInt, Double) -> Void)?
        private var sink: (@Sendable (OwnedVirtualWire) -> Void)?
        private var notify: (@Sendable (UInt32) -> Void)?
        private var generation: UInt = 0
        private var calls: [String] = []
        var failCreate: String?
        var failDispose = false
        var failSend = false
        var failDisconnect = false
        var failConnect = false
        var failPublish = false
        var failUID = false
        var holdReceipts = false
        var beforeUID: (@Sendable () -> Void)?
        var beforeDispose: (@Sendable () -> Void)?
        private var heldReceipts: [OwnedVirtualWire] = []
        private func hit(_ name: String) throws -> UInt32 {
            lock.lock(); defer { lock.unlock() }
            calls.append(name)
            if failCreate == name { throw OwnedVirtualError.operation(name, -1) }
            next += 1; return next
        }

        var recorded: [String] { lock.lock(); defer { lock.unlock() }; return calls }
        func client(_ name: String,
                    notify: @escaping @Sendable (UInt32) -> Void) throws -> UInt32
        {
            lock.lock(); self.notify = notify; lock.unlock(); return try hit("client")
        }

        func source(_ client: UInt32, _ name: String) throws -> UInt32 { try hit("source") }
        func destination(_ client: UInt32, _ name: String,
                         receive: @escaping @Sendable (OwnedVirtualWire) -> Void) throws -> UInt32
        {
            lock.lock(); sink = receive; lock.unlock(); return try hit("destination")
        }

        func inputPort(_ client: UInt32, _ name: String,
                       receive: @escaping @Sendable (OwnedVirtualWire, UInt, Double) -> Void) throws -> UInt32
        {
            lock.lock(); input = receive; lock.unlock(); return try hit("inputPort")
        }

        func outputPort(_ client: UInt32, _ name: String) throws -> UInt32 { try hit("outputPort") }
        func uniqueID(_ endpoint: UInt32) throws -> Int32 {
            lock.lock(); let callback = beforeUID; beforeUID = nil; calls.append("uid"); lock.unlock()
            callback?()
            if failUID { throw OwnedVirtualError.operation("uid", -1) }
            return Int32(endpoint)
        }

        func connect(_ port: UInt32, _ source: UInt32, generation: UInt) throws {
            lock.lock(); self.generation = generation; calls.append("connect"); lock.unlock()
            if failConnect { throw OwnedVirtualError.operation("connect", -1) }
        }

        func disconnect(_ port: UInt32, _ source: UInt32) throws {
            _ = try hit("disconnect")
            if failDisconnect { throw OwnedVirtualError.operation("disconnect", -1) }
        }

        func emitSink(_ words: [UInt32], timestamps: [UInt64]? = nil) {
            lock.lock(); let callback = sink; lock.unlock(); callback?(.init(words: words, timestamps: timestamps))
        }

        func emitNotification(_ object: UInt32) {
            lock.lock(); let callback = notify; lock.unlock(); callback?(object)
        }

        func publish(_ source: UInt32, message: MIDIVoiceMessage) throws {
            lock.lock(); let callback = input; let epoch = generation; calls.append("publish"); lock.unlock()
            if failPublish { throw OwnedVirtualError.operation("publish", -1) }
            callback?(.init(words: [try MIDI1UMPCodec.encode(message)]), epoch, ProcessInfo.processInfo.systemUptime)
        }

        func send(_ port: UInt32, _ destination: UInt32, message: MIDIVoiceMessage, timestamp: UInt64) throws {
            lock.lock(); let callback = sink; calls.append("send"); lock.unlock()
            if failSend { throw OwnedVirtualError.operation("send", -1) }
            let wire = OwnedVirtualWire(words: [try MIDI1UMPCodec.encode(message)], timestamps: [timestamp])
            if holdReceipts { lock.lock(); heldReceipts.append(wire); lock.unlock() } else { callback?(wire) }
        }

        func flushReceipts() {
            lock.lock(); let callback = sink, pending = heldReceipts; heldReceipts = []; lock.unlock()
            for wire in pending { callback?(wire) }
        }

        func emit(words: [UInt32], generation: UInt) {
            lock.lock(); let callback = input; lock.unlock()
            callback?(.init(words: words), generation, ProcessInfo.processInfo.systemUptime)
        }

        func dispose(_ ref: OwnedMIDIRef) throws {
            lock.lock(); calls.append("dispose_" + ref.kind.rawValue); lock.unlock()
            beforeDispose?()
            if failDispose { throw OwnedVirtualError.operation("dispose", -1) }
        }
    }

    private final class OwnedPeerClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 100.0
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ amount: Double) { lock.lock(); value += amount; lock.unlock() }
    }

    @MainActor
    final class OwnedVirtualMIDITests: XCTestCase {
        private func attach(_ device: OwnedVirtualRehearsalDevice) throws -> (SurfaceSession, MCPApplicationGateway) {
            let control = BCRControlID.encoder(row: 1, 1)
            let surface = SurfaceSession(
                hardwareDevice: device,
                hardwareMap: .init(entries: [.init(
                    control: control,
                    midi: .init(kind: .controlChange, channel: 0, number: 81)
                )]),
                configuration: .init(name: "bounded", parameters: [.init(id: "axis", name: "Axis", maximum: 127)],
                                     assignments: [.init(control: control, target: .parameter("axis"))]),
                hardwareOutput: .write, hardwareLifecycleFeedback: false,
                saveHardwareMap: { _ in }, saveConfiguration: { _ in }
            )
            surface.selectSource(.hardware)
            let gateway = MCPApplicationGateway(session: surface, includeAgent: false)
            try SurfaceControlMCPModule.installHardware(on: gateway, instanceID: "owned-negative")
            return (surface, gateway)
        }

        private func assertNoInput(_ surface: SurfaceSession, _ gateway: MCPApplicationGateway,
                                   file: StaticString = #filePath, line: UInt = #line)
        {
            XCTAssertEqual(surface.engine.value(of: "axis"), 0, file: file, line: line)
            let snapshot = gateway.call("surface_control_snapshot", arguments: .object([
                "instance_id": .string("owned-negative")
            ])).value
            XCTAssertEqual(snapshot.value(for: "latest_input_sequence"), .string("0"), file: file, line: line)
            XCTAssertEqual(snapshot.value(for: "inputs"), .object([:]), file: file, line: line)
        }

        private func fixture(_ api: OwnedAPIFake) throws -> OwnedVirtualRehearsalDevice {
            let control = BCRControlID.encoder(row: 1, 1)
            return try .init(
                map: .init(entries: [.init(
                    control: control,
                    midi: .init(kind: .controlChange, channel: 0, number: 81)
                )]),
                configuration: .init(name: "fixture"),
                api: api
            )
        }

        func testProductionGraphOnlyReturnedRefsAndForeignRefOrEnumerationAreRejectedBeforeAPI() async throws {
            let api = OwnedAPIFake(), graph = OwnedVirtualMIDIGraph(api: api)
            let snapshot = try await graph.start()
            XCTAssertTrue(snapshot.isConnected)
            let audit = graph.audit().objectValue!
            let made = audit["created_refs"]!.arrayValue!
            let destination = try XCTUnwrap(made.first { $0.value(for: "kind") == .string("destination") })
            let owner = try XCTUnwrap(UUID(uuidString: destination.value(for: "owner")!.stringValue!))
            let fake = OwnedMIDIRef(raw: 99999, kind: .destination, owner: owner)
            XCTAssertThrowsError(try graph.send(.controlChange(channel: 0, number: 81, value: 4), destination: fake))
            XCTAssertFalse(api.recorded.contains("send"))
            XCTAssertThrowsError(try OwnedCallPolicy().validate("MIDIGetNumberOfSources", refs: [], owned: []))
            XCTAssertTrue(graph.stop().isEmpty)
            XCTAssertEqual(api.recorded.filter { $0.hasPrefix("dispose_") },
                           [
                               "dispose_outputPort",
                               "dispose_inputPort",
                               "dispose_destination",
                               "dispose_source",
                               "dispose_client"
                           ])
            XCTAssertEqual(graph.audit().value(for: "unconfirmed_cleanup_refs"), .array([]))
        }

        func testInputCallbackAndDisplaySinkRemainSeparateAndLifecycleSendsNothing() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            var inputs = 0
            let received = expectation(description: "actual input callback")
            device.onInputBatch = { batch in
                inputs += 1
                XCTAssertEqual(batch.endpoint.provenance, .localVirtual)
                received.fulfill()
            }
            try await device.start()
            XCTAssertFalse(api.recorded.contains("send"))
            try device.peer(.object([
                "operation": .string("input"),
                "control": try .encoded(BCRControlID.encoder(row: 1, 1)),
                "value": .number(10)
            ]))
            await fulfillment(of: [received], timeout: 1)
            try device.send(.controlChange(channel: 0, number: 81, value: 64))
            await Task.yield()
            XCTAssertEqual(inputs, 1)
            XCTAssertEqual(api.recorded.filter { $0 == "send" }.count, 1)
            try device.peer(.object(["operation": .string("disconnect")]))
            try device.peer(.object(["operation": .string("reconnect")]))
            XCTAssertEqual(api.recorded.filter { $0 == "send" }.count, 1)
            XCTAssertTrue(device.stop().isEmpty)
            XCTAssertEqual(api.recorded.filter { $0 == "send" }.count, 1)
        }

        func testPartialStartupAndCleanupFailuresAreVisibleAndNeverUseOtherRefs() async throws {
            let api = OwnedAPIFake(); api.failCreate = "outputPort"
            let graph = OwnedVirtualMIDIGraph(api: api)
            do { _ = try await graph.start(); XCTFail("startup accepted failed factory") } catch {}
            XCTAssertEqual(api.recorded.filter { $0.hasPrefix("dispose_") },
                           ["dispose_inputPort", "dispose_destination", "dispose_source", "dispose_client"])
            XCTAssertFalse(api.recorded.contains("connect"))
            let second = OwnedAPIFake(), badCleanup = OwnedVirtualMIDIGraph(api: second)
            _ = try await badCleanup.start(); second.failDispose = true
            XCTAssertFalse(badCleanup.stop().isEmpty)
            XCTAssertFalse(badCleanup.audit().value(for: "unconfirmed_cleanup_refs")!.arrayValue!.isEmpty)
            let attempted = second.recorded
            XCTAssertFalse(badCleanup.stop().isEmpty)
            XCTAssertEqual(second.recorded, attempted) // Uncertain cleanup is visible, never retried.
        }

        func testDisplaySystemFailureRevokesRouteWithoutInputOrRetry() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            var inputs = 0
            device.onInputBatch = { _ in inputs += 1 }
            try await device.start()
            let old = device.connection.transportGeneration
            api.failSend = true
            XCTAssertThrowsError(try device.send(.controlChange(channel: 0, number: 81, value: 64)))
            XCTAssertFalse(device.connection.isConnected)
            XCTAssertNotEqual(device.connection.transportGeneration, old)
            XCTAssertEqual(device.connection.lastError, "owned_display_transport_failed")
            XCTAssertEqual(api.recorded.filter { $0 == "send" }.count, 1)
            XCTAssertEqual(device.audit.value(for: "display_receipts"), .array([]))
            XCTAssertEqual(inputs, 0)
            XCTAssertFalse(device.stop().isEmpty)
            XCTAssertEqual(api.recorded.filter { $0 == "send" }.count, 1)
        }

        func testStaleCallbackGenerationAndOverflowCannotBecomeInputs() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            var inputs = 0
            device.onInputBatch = { _ in inputs += 1 }
            let fault = expectation(description: "bounded callback overflow is visible")
            device.onConnection = { snapshot in if snapshot.lastError == "owned_callback_overflow" { fault.fulfill() } }
            try await device.start()
            try device.peer(.object(["operation": .string("disconnect")]))
            try device.peer(.object(["operation": .string("reconnect")]))
            api.emit(words: [try MIDI1UMPCodec.encode(.controlChange(channel: 0, number: 81, value: 5))], generation: 1)
            api.emit(words: Array(repeating: 0, count: 257), generation: 3)
            await fulfillment(of: [fault], timeout: 1)
            XCTAssertEqual(inputs, 0)
            XCTAssertFalse(device.connection.isConnected)
            XCTAssertFalse(device.stop().isEmpty)
        }

        func testPrivatePeerRejectsNonFIFOWithoutCreatingAnotherSystemRoute() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            try await device.start()
            let file = open("/dev/null", O_RDONLY)
            defer { close(file) }
            XCTAssertThrowsError(try device.startPeer(fd: file))
            XCTAssertEqual(api.recorded.filter { $0 == "client" }.count, 1)
            XCTAssertTrue(device.stop().isEmpty)
        }

        func testHandoffCapacityIncludesMainActorTasksAndOverflowRevokesPendingInputs() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            let control = BCRControlID.encoder(row: 1, 1)
            let surface = SurfaceSession(
                hardwareDevice: device,
                hardwareMap: .init(entries: [.init(
                    control: control, midi: .init(kind: .controlChange, channel: 0, number: 81)
                )]),
                configuration: .init(name: "bounded", parameters: [.init(id: "axis", name: "Axis", maximum: 127)],
                                     assignments: [.init(control: control, target: .parameter("axis"))]),
                hardwareOutput: .write, hardwareLifecycleFeedback: false,
                saveHardwareMap: { _ in }, saveConfiguration: { _ in }
            )
            surface.selectSource(.hardware)
            let gateway = MCPApplicationGateway(session: surface, includeAgent: false)
            try SurfaceControlMCPModule.installHardware(on: gateway, instanceID: "bounded-owned")
            var inputs = 0
            let originalInput = device.onInputBatch
            device.onInputBatch = { batch in inputs += 1; originalInput?(batch) }
            let fault = expectation(description: "MainActor handoff capacity is bounded")
            let originalConnection = device.onConnection
            device.onConnection = { snapshot in
                originalConnection?(snapshot)
                if snapshot.lastError == "owned_callback_overflow" { fault.fulfill() }
            }
            try await device.start()
            let word = try MIDI1UMPCodec.encode(.controlChange(channel: 0, number: 81, value: 5))
            // The MainActor stays occupied. Drain the graph queue after each callback,
            // so a graph-only counter cannot pass this delayed-consumer test.
            for _ in 0 ..< 257 {
                api.emit(words: [word], generation: 1)
                _ = device.audit
            }
            await fulfillment(of: [fault], timeout: 1)
            XCTAssertEqual(inputs, 0)
            XCTAssertEqual(surface.engine.value(of: "axis"), 0)
            XCTAssertEqual(surface.inputEvents.snapshot().value(for: "events")?.arrayValue?.map {
                $0.value(for: "kind")
            }, [.string("context.changed")])
            let snapshot = gateway.call("surface_control_snapshot", arguments: .object([
                "instance_id": .string("bounded-owned")
            ])).value
            XCTAssertEqual(snapshot.value(for: "latest_input_sequence"), .string("0"))
            XCTAssertEqual(snapshot.value(for: "inputs"), .object([:]))
            XCTAssertEqual(device.audit.value(for: "pending_input_tickets"), .number(0))
            XCTAssertFalse(device.connection.isConnected)
            XCTAssertFalse(device.stop().isEmpty)
        }

        func testHandoffTicketReturnsCapacityOnceOnFinishOrOwnerRelease() async {
            let explicit = expectation(description: "explicit ticket returns once")
            let abandoned = expectation(description: "unconsumed ticket returns on release")
            var ticket: OwnedVirtualInputTicket? = .init { explicit.fulfill() }
            ticket?.finish(); ticket?.finish(); ticket = nil
            var unused: OwnedVirtualInputTicket? = .init { abandoned.fulfill() }
            XCTAssertNotNil(unused); unused = nil
            await fulfillment(of: [explicit, abandoned], timeout: 1)
        }

        func testUnknownVisualizationOnlyAndRawPeerCommandsCannotInjectAnything() async throws {
            let api = OwnedAPIFake(), control = BCRControlID.button(row: 1, 1)
            let device = try OwnedVirtualRehearsalDevice(
                map: .init(entries: [.init(
                    control: control,
                    midi: .init(kind: .controlChange, channel: 0, number: 81),
                    visualizationOnly: true
                )]),
                configuration: .init(name: "fixture"), api: api
            )
            try await device.start()
            XCTAssertThrowsError(try device.peer(.object([
                "operation": .string("input"),
                "control": try .encoded(control),
                "value": .bool(true)
            ])))
            XCTAssertThrowsError(try device.peer(.object([
                "operation": .string("input"),
                "destination": .number(999),
                "bytes": .array([])
            ])))
            XCTAssertThrowsError(try device.send(.controlChange(channel: 0, number: 81, value: 1)))
            XCTAssertFalse(api.recorded.contains("send")); XCTAssertFalse(api.recorded.contains("publish"))
            XCTAssertTrue(device.stop().isEmpty)
        }

        func testWholeUMPBatchRejectsMixedAndHighBitWithoutPartialInput() async throws {
            for words: [UInt32] in [[0x20B05105, 0], [0x20B05185], [0x20B0D105], [0x40B05105]] {
                let api = OwnedAPIFake(), device = try fixture(api)
                let (surface, gateway) = try attach(device)
                let original = device.onInputBatch
                var inputs = 0
                device.onInputBatch = { batch in inputs += 1; original?(batch) }
                try await device.start()
                api.emit(words: words, generation: 1)
                _ = device.audit
                await Task.yield()
                XCTAssertEqual(inputs, 0, "raw batch \(words)")
                XCTAssertFalse(device.connection.isConnected, "raw batch \(words)")
                assertNoInput(surface, gateway)
                XCTAssertFalse(api.recorded.contains("send"))
                _ = device.stop()
            }
        }

        func testReceiptFloodIsBoundedAndRevokesWithoutInput() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            let (surface, gateway) = try attach(device)
            var inputs = 0
            device.onInputBatch = { _ in inputs += 1 }
            try await device.start()
            for _ in 0 ..< 100 { api.emitSink(Array(repeating: 0x20B05140, count: 256)) }
            _ = device.audit
            await Task.yield()
            let audit = device.audit
            XCTAssertLessThanOrEqual(audit.value(for: "failures")!.arrayValue!.count, 64)
            XCTAssertLessThanOrEqual(audit.value(for: "display_receipts")!.arrayValue!.count, 4096)
            XCTAssertFalse(device.connection.isConnected)
            XCTAssertEqual(inputs, 0)
            assertNoInput(surface, gateway)
            XCTAssertFalse(api.recorded.contains("send"))
            XCTAssertEqual(audit.value(for: "receipt_ingress")?.value(for: "pending_tasks"), .number(0))
            _ = device.stop()
        }

        func testTerminalStopCannotReenterConnectOrHidePriorCleanupFailure() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            try await device.start(); api.failDispose = true
            device.onConnection = { _ in
                device.onConnection = nil
                do { try device.peer(.object(["operation": .string("reconnect")])); XCTFail("reconnected after stop")
                } catch {}
                do { try device.send(.controlChange(channel: 0, number: 81, value: 64)); XCTFail("sent after stop")
                } catch {}
                XCTAssertFalse(device.stop().isEmpty)
            }
            let first = device.stop()
            XCTAssertFalse(first.isEmpty)
            XCTAssertEqual(device.stop(), first)
            XCTAssertEqual(api.recorded.filter { $0 == "connect" }.count, 1)
            XCTAssertEqual(api.recorded.filter { $0 == "send" }.count, 0)
            let second = OwnedAPIFake(), graph = OwnedVirtualMIDIGraph(api: second)
            _ = try await graph.start(); second.failDispose = true
            second.beforeDispose = {
                do { _ = try graph.reconnect(); XCTFail("graph revived during dispose") } catch {}
                do { try graph.send(.controlChange(
                    channel: 0,
                    number: 81,
                    value: 64
                )); XCTFail("graph sent during dispose") } catch {}
                XCTAssertEqual(graph.stop(), ["owned_cleanup_in_progress"])
            }
            let result = graph.stop(); second.beforeDispose = nil
            XCTAssertFalse(result.isEmpty); XCTAssertEqual(graph.stop(), result)
            XCTAssertEqual(second.recorded.filter { $0 == "connect" }.count, 1)
            XCTAssertFalse(second.recorded.contains("send"))
        }

        func testDisconnectFailureRevokesBeforeAnyImplicitRetry() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            try await device.start(); api.failDisconnect = true
            XCTAssertThrowsError(try device.peer(.object(["operation": .string("disconnect")])))
            XCTAssertFalse(device.connection.isConnected)
            XCTAssertThrowsError(try device.peer(.object(["operation": .string("reconnect")])))
            _ = device.stop()
            XCTAssertEqual(api.recorded.filter { $0 == "disconnect" }.count, 1)
            XCTAssertEqual(api.recorded.filter { $0 == "connect" }.count, 1)
        }

        func testPrivatePeerManyReadsCannotAccumulateBehindBlockedOwner() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            let (surface, gateway) = try attach(device)
            var descriptors = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(pipe(&descriptors), 0)
            _ = fcntl(descriptors[1], F_SETNOSIGPIPE, 1)
            defer { close(descriptors[1]) }
            var inputs = 0
            device.onInputBatch = { _ in inputs += 1 }
            let fault = expectation(description: "peer ingress capacity revokes pending commands")
            device.onConnection = { snapshot in
                if snapshot.lastError == "private_peer_capacity_exhausted" { fault.fulfill() }
            }
            try await device.start(); try device.startPeer(fd: descriptors[0])
            let line = Data("{\"operation\":\"input\",\"control\":{\"section\":\"encoder\",\"row\":1,\"index\":1},\"value\":5}\n"
                .utf8)
            for _ in 0 ..< 80 {
                let amount = line.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
                if amount < 0 { break }
                usleep(3000) // Deliberately occupy the owner while many separate FD reads run.
            }
            await fulfillment(of: [fault], timeout: 1)
            XCTAssertEqual(inputs, 0)
            XCTAssertEqual(api.recorded.filter { $0 == "publish" }.count, 0)
            XCTAssertFalse(device.connection.isConnected)
            assertNoInput(surface, gateway)
            let peer = device.audit.value(for: "peer_ingress")!
            XCTAssertGreaterThan(peer.value(for: "read_count")!.exactIntValue!, 1)
            XCTAssertLessThanOrEqual(peer.value(for: "peak_tasks")!.exactIntValue!, 16)
            XCTAssertLessThanOrEqual(peer.value(for: "peak_units")!.exactIntValue!, 64)
            XCTAssertLessThanOrEqual(peer.value(for: "peak_bytes")!.exactIntValue!, 65536)
            XCTAssertEqual(peer.value(for: "pending_tasks"), .number(0))
            _ = device.stop()
        }

        func testPeerFirstByteTimeCannotBeWashedByLateNewlineOrOwnerConsumption() async throws {
            let api = OwnedAPIFake(), clock = OwnedPeerClock()
            let device = try OwnedVirtualRehearsalDevice(
                map: .init(entries: [.init(
                    control: .encoder(row: 1, 1),
                    midi: .init(kind: .controlChange, channel: 0, number: 81)
                )]),
                configuration: .init(name: "time"), api: api, peerClock: { clock.now() }
            )
            let (surface, gateway) = try attach(device)
            var descriptors = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(pipe(&descriptors), 0); _ = fcntl(descriptors[1], F_SETNOSIGPIPE, 1)
            defer { close(descriptors[1]) }
            let fault = expectation(description: "old private peer command rejected")
            let original = device.onConnection
            device.onConnection = { snapshot in
                original?(snapshot)
                if snapshot.lastError == "private_peer_handoff_lag" { fault.fulfill() }
            }
            try await device.start(); try device.startPeer(fd: descriptors[0])
            let prefix = Data("{\"operation\":\"input\",\"control\":{\"section\":\"encoder\",\"row\":1,\"index\":1},\"value\":5}"
                .utf8)
            _ = prefix.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
            for _ in 0 ..< 1000 {
                if device.audit.value(for: "peer_ingress")?.value(for: "buffer_bytes")?.exactIntValue == prefix
                    .count { break }
                usleep(1000)
            }
            XCTAssertEqual(
                device.audit.value(for: "peer_ingress")?.value(for: "oldest_buffer_received_at"),
                .double(100)
            )
            clock.advance(3)
            var newline: UInt8 = 10; XCTAssertEqual(write(descriptors[1], &newline, 1), 1)
            await fulfillment(of: [fault], timeout: 1)
            assertNoInput(surface, gateway)
            XCTAssertFalse(api.recorded.contains("publish")); XCTAssertFalse(api.recorded.contains("send"))
            XCTAssertEqual(device.audit.value(for: "peer_ingress")?.value(for: "pending_tasks"), .number(0))
            _ = device.stop()
        }

        func testEveryPeerCommandRechecksReadTimeAfterSynchronousReport() async throws {
            let api = OwnedAPIFake(), clock = OwnedPeerClock()
            var reports = 0
            let device = try OwnedVirtualRehearsalDevice(
                map: .init(entries: [.init(
                    control: .encoder(row: 1, 1),
                    midi: .init(kind: .controlChange, channel: 0, number: 81)
                )]),
                configuration: .init(name: "per-command-time"), api: api,
                report: { value in
                    if value.value(for: "event") == .string("owned_virtual.reconnected") {
                        reports += 1
                        clock.advance(3) // A synchronous report can delay the next command in this same batch.
                    }
                }, peerClock: { clock.now() }
            )
            let (surface, gateway) = try attach(device)
            var callbacks = 0, faults = 0
            let originalInput = device.onInputBatch, originalConnection = device.onConnection
            device.onInputBatch = { batch in callbacks += 1; originalInput?(batch) }
            let rejected = expectation(description: "second command expires during the first report")
            device.onConnection = { snapshot in
                originalConnection?(snapshot)
                if snapshot.lastError == "private_peer_handoff_lag" { faults += 1; rejected.fulfill() }
            }
            try await device.start()
            let generation = device.connection.transportGeneration
            var descriptors = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(pipe(&descriptors), 0); defer { close(descriptors[1]) }
            try device.startPeer(fd: descriptors[0])
            let lines = Data("{\"operation\":\"reconnect\"}\n{\"operation\":\"input\",\"control\":{\"section\":\"encoder\",\"row\":1,\"index\":1},\"value\":5}\n"
                .utf8)
            XCTAssertEqual(lines.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }, lines.count)
            await fulfillment(of: [rejected], timeout: 1)
            XCTAssertEqual(reports, 1)
            XCTAssertEqual(api.recorded.filter { $0 == "connect" }.count,
                           1) // Same-route reconnect did not change scope.
            XCTAssertNotEqual(device.connection.transportGeneration, generation) // Only the expiry fault revokes it.
            XCTAssertEqual(faults, 1)
            XCTAssertEqual(callbacks, 0)
            XCTAssertFalse(api.recorded.contains("publish")); XCTAssertFalse(api.recorded.contains("send"))
            assertNoInput(surface, gateway)
            XCTAssertEqual(device.audit.value(for: "peer_ingress")?.value(for: "pending_tasks"), .number(0))
            XCTAssertEqual(device.audit.value(for: "peer_ingress")?.value(for: "pending_units"), .number(0))
            XCTAssertEqual(device.audit.value(for: "peer_ingress")?.value(for: "pending_bytes"), .number(0))
            _ = device.stop()
        }

        func testPeerBatchStopsAfterSynchronousTerminalConnectionCallback() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            let (surface, gateway) = try attach(device)
            try await device.start()
            let finished = expectation(description: "terminal stop inside disconnect callback")
            let original = device.onConnection
            device.onConnection = { snapshot in
                original?(snapshot)
                if !snapshot.isConnected {
                    device.onConnection = nil
                    _ = device.stop(); finished.fulfill()
                }
            }
            var descriptors = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(pipe(&descriptors), 0); defer { close(descriptors[1]) }
            try device.startPeer(fd: descriptors[0])
            let lines = Data("{\"operation\":\"disconnect\"}\n{\"operation\":\"input\",\"control\":{\"section\":\"encoder\",\"row\":1,\"index\":1},\"value\":5}\n"
                .utf8)
            _ = lines.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
            await fulfillment(of: [finished], timeout: 1)
            assertNoInput(surface, gateway)
            XCTAssertFalse(api.recorded.contains("publish")); XCTAssertFalse(api.recorded.contains("send"))
            XCTAssertEqual(device.audit.value(for: "peer_ingress")?.value(for: "pending_tasks"), .number(0))
            XCTAssertTrue(device.stop().isEmpty)
            XCTAssertThrowsError(try device.peer(.object(["operation": .string("reconnect")])))
        }

        func testPublishConnectAndUIDErrorsRevokeWithoutInputOrImplicitRetry() async throws {
            for operation in ["publish", "connect", "uid"] {
                let api = OwnedAPIFake(), device = try fixture(api)
                let (surface, gateway) = try attach(device)
                try await device.start()
                switch operation {
                case "publish":
                    api.failPublish = true
                    XCTAssertThrowsError(try device.peer(.object([
                        "operation": .string("input"), "control": try .encoded(BCRControlID.encoder(row: 1, 1)),
                        "value": .number(5)
                    ])))
                case "connect":
                    try device.peer(.object(["operation": .string("disconnect")]))
                    api.failConnect = true
                    XCTAssertThrowsError(try device.peer(.object(["operation": .string("reconnect")])))
                    XCTAssertThrowsError(try device.peer(.object(["operation": .string("reconnect")])))
                    XCTAssertEqual(api.recorded.filter { $0 == "connect" }.count, 2)
                default:
                    api.failUID = true
                    XCTAssertThrowsError(try device.send(.controlChange(channel: 0, number: 81, value: 64)))
                }
                _ = device.audit; await Task.yield()
                XCTAssertFalse(device.connection.isConnected, operation)
                assertNoInput(surface, gateway)
                XCTAssertFalse(api.recorded.contains("send"))
                let disconnected = api.recorded.filter { $0 == "disconnect" }.count
                _ = device.stop()
                XCTAssertEqual(api.recorded.filter { $0 == "disconnect" }.count, disconnected)
                XCTAssertEqual(device.audit.value(for: "pending_input_tickets"), .number(0))
            }
        }

        func testDelayedReceiptKeepsOriginalSendGenerationAndRawUMPSeparate() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            let (surface, gateway) = try attach(device)
            try await device.start(); api.holdReceipts = true
            try device.send(.controlChange(channel: 0, number: 81, value: 64))
            try device.peer(.object(["operation": .string("disconnect")]))
            try device.peer(.object(["operation": .string("reconnect")]))
            XCTAssertEqual(api.recorded.filter { $0 == "send" }.count, 1)
            api.flushReceipts()
            let first = try XCTUnwrap(device.audit.value(for: "display_receipt_records")?.arrayValue?.first)
            XCTAssertEqual(first.value(for: "raw_ump_words"), .array([.number(0x20B05140)]))
            XCTAssertEqual(
                first.value(for: "normalized_midi1_bytes"),
                .array([.array([.number(176), .number(81), .number(64)])])
            )
            XCTAssertEqual(first.value(for: "send_generations"), .array([.number(1)]))
            XCTAssertEqual(first.value(for: "callback_generation"), .number(3))
            XCTAssertEqual(first.value(for: "current_scope"), .array([.bool(false)]))
            try device.send(.controlChange(channel: 0, number: 81, value: 65)); api.flushReceipts()
            let current = try XCTUnwrap(device.audit.value(for: "display_receipt_records")?.arrayValue?.last)
            XCTAssertEqual(current.value(for: "send_generations"), .array([.number(3)]))
            XCTAssertEqual(current.value(for: "current_scope"), .array([.bool(true)]))
            assertNoInput(surface, gateway)
            XCTAssertFalse(api.recorded.contains("publish"))
            XCTAssertEqual(device.audit.value(for: "receipt_ingress")?.value(for: "pending_tasks"), .number(0))
            XCTAssertTrue(device.stop().isEmpty)
        }

        func testUnrelatedNotificationsQueueNothingAndOwnedStormSafelyCoalesces() async throws {
            let api = OwnedAPIFake(), graph = OwnedVirtualMIDIGraph(api: api)
            _ = try await graph.start()
            let source = try XCTUnwrap(graph.audit().value(for: "created_refs")?.arrayValue?
                .first { $0.value(for: "kind") == .string("source") }?.value(for: "ref")?.exactIntValue)
            let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
            api.beforeUID = { entered.signal(); released.wait() }
            let sending = Task.detached { try graph.send(.controlChange(channel: 0, number: 81, value: 64)) }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            for _ in 0 ..< 10000 { api.emitNotification(99999); api.emitNotification(UInt32(source)) }
            let ingress = graph.ingressAudit
            XCTAssertEqual(ingress.value(for: "unrelated_notifications"), .number(10000))
            XCTAssertEqual(ingress.value(for: "notification_pending"), .number(1))
            XCTAssertEqual(ingress.value(for: "notification_enqueued"), .number(1))
            XCTAssertEqual(ingress.value(for: "notification_coalesced"), .number(9999))
            released.signal(); try await sending.value
            for _ in 0 ..< 3 { _ = graph.audit() }
            XCTAssertEqual(graph.ingressAudit.value(for: "notification_pending"), .number(0))
            XCTAssertFalse(api.recorded.contains("publish"))
            XCTAssertTrue(graph.stop().isEmpty)
        }

        func testReceiptIngressFaultCancelsAdmittedSendAtBlockedUIDBoundary() async throws {
            let api = OwnedAPIFake(), graph = OwnedVirtualMIDIGraph(api: api)
            _ = try await graph.start()
            let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
            api.beforeUID = { entered.signal(); released.wait() }
            let sending = Task.detached { try graph.send(.controlChange(channel: 0, number: 81, value: 64)) }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            for _ in 0 ..< 10000 { api.emitSink(Array(repeating: 0x20B05140, count: 256)) }
            let pending = graph.receiptIngressAudit
            XCTAssertLessThanOrEqual(pending.value(for: "pending_tasks")!.exactIntValue!, 64)
            XCTAssertLessThanOrEqual(pending.value(for: "pending_units")!.exactIntValue!, 4096)
            XCTAssertLessThanOrEqual(pending.value(for: "pending_bytes")!.exactIntValue!, 16384)
            released.signal()
            do { try await sending.value; XCTFail("send survived a sealed callback scope") } catch {}
            let audit = graph.audit()
            XCTAssertFalse(graph.currentSnapshot.isConnected)
            XCTAssertFalse(api.recorded.contains("send")); XCTAssertFalse(api.recorded.contains("publish"))
            XCTAssertEqual(audit.value(for: "receipt_ingress")?.value(for: "pending_tasks"), .number(0))
            XCTAssertLessThanOrEqual(audit.value(for: "failures")!.arrayValue!.count, 2)
            _ = graph.stop()
        }

        func testReceiptStorageRejectsEntireCrossLimitBatchAndCallsRemainBounded() async throws {
            let api = OwnedAPIFake(), device = try fixture(api)
            let (surface, gateway) = try attach(device)
            try await device.start()
            for _ in 0 ..< 15 { api.emitSink(Array(repeating: 0x20B05140, count: 256)); _ = device.audit }
            api.emitSink(Array(repeating: 0x20B05140, count: 255)); _ = device.audit
            api.emitSink([0x20B05140, 0x20B05140]); _ = device.audit
            await Task.yield()
            XCTAssertEqual(device.audit.value(for: "display_receipts")?.arrayValue?.count, 4095)
            XCTAssertFalse(device.connection.isConnected); assertNoInput(surface, gateway)
            XCTAssertEqual(device.audit.value(for: "receipt_ingress")?.value(for: "pending_tasks"), .number(0))
            _ = device.stop()
            let second = OwnedAPIFake(), graph = OwnedVirtualMIDIGraph(api: second)
            _ = try await graph.start()
            for _ in 0 ..< 2200 { try graph.send(.controlChange(channel: 0, number: 81, value: 64)) }
            let audit = graph.audit()
            XCTAssertEqual(audit.value(for: "calls")?.arrayValue?.count, 4096)
            XCTAssertGreaterThan(audit.value(for: "dropped_call_records")!.exactIntValue!, 0)
            XCTAssertEqual(audit.value(for: "receipt_ingress")?.value(for: "pending_tasks"), .number(0))
            XCTAssertTrue(graph.stop().isEmpty)
            XCTAssertThrowsError(try graph.reconnect())
        }
    }
#endif
