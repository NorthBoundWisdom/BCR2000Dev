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
        private var input: (@Sendable ([UInt32], UInt, Double) -> Void)?
        private var sink: (@Sendable ([UInt32]) -> Void)?
        private var generation: UInt = 0
        private var calls: [String] = []
        var failCreate: String?
        var failDispose = false
        var failSend = false
        private func hit(_ name: String) throws -> UInt32 {
            lock.lock(); defer { lock.unlock() }
            calls.append(name)
            if failCreate == name { throw OwnedVirtualError.operation(name, -1) }
            next += 1; return next
        }

        var recorded: [String] { lock.lock(); defer { lock.unlock() }; return calls }
        func client(_ name: String,
                    notify _: @escaping @Sendable (UInt32) -> Void) throws -> UInt32 { try hit("client") }
        func source(_ client: UInt32, _ name: String) throws -> UInt32 { try hit("source") }
        func destination(_ client: UInt32, _ name: String,
                         receive: @escaping @Sendable ([UInt32]) -> Void) throws -> UInt32
        {
            lock.lock(); sink = receive; lock.unlock(); return try hit("destination")
        }

        func inputPort(_ client: UInt32, _ name: String,
                       receive: @escaping @Sendable ([UInt32], UInt, Double) -> Void) throws -> UInt32
        {
            lock.lock(); input = receive; lock.unlock(); return try hit("inputPort")
        }

        func outputPort(_ client: UInt32, _ name: String) throws -> UInt32 { try hit("outputPort") }
        func uniqueID(_ endpoint: UInt32) throws -> Int32 { Int32(endpoint) }
        func connect(_ port: UInt32, _ source: UInt32, generation: UInt) throws {
            lock.lock(); self.generation = generation; calls.append("connect"); lock.unlock()
        }

        func disconnect(_ port: UInt32, _ source: UInt32) throws { _ = try hit("disconnect") }
        func publish(_ source: UInt32, message: MIDIVoiceMessage) throws {
            lock.lock(); let callback = input; let epoch = generation; calls.append("publish"); lock.unlock()
            callback?([try MIDI1UMPCodec.encode(message)], epoch, ProcessInfo.processInfo.systemUptime)
        }

        func send(_ port: UInt32, _ destination: UInt32, message: MIDIVoiceMessage) throws {
            lock.lock(); let callback = sink; calls.append("send"); lock.unlock()
            if failSend { throw OwnedVirtualError.operation("send", -1) }
            callback?([try MIDI1UMPCodec.encode(message)])
        }

        func emit(words: [UInt32], generation: UInt) {
            lock.lock(); let callback = input; lock.unlock()
            callback?(words, generation, ProcessInfo.processInfo.systemUptime)
        }

        func dispose(_ ref: OwnedMIDIRef) throws {
            lock.lock(); calls.append("dispose_" + ref.kind.rawValue); lock.unlock()
            if failDispose { throw OwnedVirtualError.operation("dispose", -1) }
        }
    }

    @MainActor
    final class OwnedVirtualMIDITests: XCTestCase {
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
    }
#endif
