import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import Foundation
import XCTest

@MainActor
private final class WriteGateDevice: SurfaceDevice, SurfaceInputObserving {
    var connection = MIDIConnectionSnapshot(connectedSource: "same", connectedDestination: "same")
    var onInputBatch: (@MainActor (SurfaceInputBatch) -> Void)?
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    var onSend: (() -> Void)?
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message); onSend?() }
    func route(_ id: Int32, provenance: MIDIEndpointProvenance) {
        connection.connectedSourceID = id; connection.connectedDestinationID = id
        connection.sourceEndpoints = [.init(id: id, name: "same", provenance: provenance)]
        connection.destinationEndpoints = connection.sourceEndpoints
        onConnection?(connection)
    }
}

@MainActor
final class DynamicParameterWriteTests: XCTestCase {
    private func fixture() -> (SurfaceSession, WriteGateDevice) {
        let device = WriteGateDevice()
        let config = SurfaceConfiguration(name: "gate", parameters: [
            .init(id: "x", name: "x", minimum: 0, maximum: 127),
            .init(id: "y", name: "y", minimum: 0, maximum: 127)
        ], assignments: [.init(control: .pushEncoder(group: 1, 1), target: .parameter("x")),
                         .init(control: .pushEncoder(group: 1, 2), target: .parameter("y"))])
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(), configuration: config,
                                     hardwareLifecycleFeedback: false,
                                     now: { Date(timeIntervalSinceReferenceDate: 100) },
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        return (session, device)
    }

    func testRevocationRejectsLocalRemoteAndHistoryWithoutMutationOrOutput() async throws {
        let (s, d) = fixture(); s.selectSource(.hardware)
        try s.setAuthorizedParameter("x", to: 10)
        d.sent.removeAll(); let history = s.valueHistory.undoEntry
        let gateway = MCPApplicationGateway(session: s)
        s.configureParameterWrites(allowsWrite: false, allowsDisplay: false)
        XCTAssertThrowsError(try s.setAuthorizedParameter("x", to: 64))
        XCTAssertTrue(gateway.call("set_parameter", arguments: .object(["id": .string("x"), "value": .number(64)]))
            .isError)
        XCTAssertThrowsError(try s.undo())
        s.turn(.pushEncoder(group: 1, 1), by: 10)
        XCTAssertEqual(s.engine.value(of: "x"), 10)
        XCTAssertEqual(s.valueHistory.undoEntry, history)
        XCTAssertTrue(d.sent.isEmpty)
    }

    func testUndoAuthorityCallbackRevocationOrRouteChangeCannotCommitOrConsumeHistory() async throws {
        for changesRoute in [false, true] {
            let (s, d) = fixture(); s.selectSource(.hardware)
            try s.setAuthorizedParameters([("x", 64), ("y", 64)], identity: .local)
            let history = s.valueHistory.undoEntry
            s.configureParameterWrites(allowsWrite: true, allowsDisplay: true)
            let sequence = s.inputEvents.sequence
            d.sent.removeAll()
            s.parameterAuthority = { request in
                if request.parameter == "y" {
                    if changesRoute { d.route(7, provenance: .remoteVirtual) }
                    else { s.configureParameterWrites(allowsWrite: false, allowsDisplay: false) }
                }
                return .accept
            }
            XCTAssertThrowsError(try s.undo())
            XCTAssertEqual(s.engine.value(of: "x"), 64)
            XCTAssertEqual(s.engine.value(of: "y"), 64)
            XCTAssertEqual(s.valueHistory.undoEntry, history)
            // A route change legitimately emits lifecycle invalidation, but never parameter.write.
            if !changesRoute { XCTAssertEqual(s.inputEvents.sequence, sequence) }
            XCTAssertTrue(d.sent.isEmpty)
        }
    }

    func testValueAndDisplayDirectionsAreIndependentAndResetCannotBypassGate() async throws {
        let (s, d) = fixture(); s.selectSource(.hardware)
        s.configureParameterWrites(allowsWrite: true, allowsDisplay: false)
        try s.setAuthorizedParameter("x", to: 64)
        XCTAssertEqual(s.engine.value(of: "x"), 64)
        XCTAssertTrue(d.sent.isEmpty)
        s.configureParameterWrites(allowsWrite: false, allowsDisplay: true)
        s.resetGroup("")
        XCTAssertEqual(s.engine.value(of: "x"), 64)
        XCTAssertTrue(d.sent.isEmpty)
    }

    func testDefaultRemoteBatchRetainsPerEntryResultsAcrossSynchronousLaterMutation() async throws {
        let (s, d) = fixture(); s.selectSource(.hardware)
        let yAddress = try XCTUnwrap(s.engine.hardwareMap.midi(for: .pushEncoder(group: 1, 2)))
        var changed = false
        d.onSend = {
            if !changed, d.sent.last?.controlID == yAddress {
                changed = true; s.setParameter("x", to: 99)
            }
        }
        let gateway = MCPApplicationGateway(session: s)
        let result = gateway.call("set_parameters", arguments: .object(["values": .array([
            .object(["id": .string("x"), "value": .number(10)]),
            .object(["id": .string("y"), "value": .number(20)])
        ])]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.value.arrayValue?.first?.objectValue?["value"], .double(10))
        XCTAssertEqual(s.engine.value(of: "x"), 99)
    }

    func testDefaultContextKeepsLocalIdentityIndependentOfRemoteRole() async throws {
        let (s, _) = fixture()
        let gateway = MCPApplicationGateway(session: s, permissions: .init(parameterWrite: false))
        XCTAssertTrue(gateway.call("set_parameter", arguments: .object(["id": .string("x"), "value": .number(64)]))
            .isError)
        try s.setAuthorizedParameter("x", to: 64)
        XCTAssertEqual(s.engine.value(of: "x"), 64)
    }

    func testAuthorityRejectionRestoresOnlyCanonicalValueWithoutSendInputOrHistory() async throws {
        let (s, d) = fixture(); s.selectSource(.hardware)
        let input = s.inputEvents.sequence; let history = s.valueHistory.undoEntry
        s.parameterAuthority = { _ in .reject(actual: 10, reason: "authority_denied") }
        XCTAssertThrowsError(try s.setAuthorizedParameter("x", to: 100))
        XCTAssertEqual(s.engine.value(of: "x"), 10)
        XCTAssertEqual(s.inputEvents.sequence, input)
        XCTAssertEqual(s.valueHistory.undoEntry, history)
        XCTAssertTrue(d.sent.isEmpty)
        XCTAssertNil(s.engine.state(of: .pushEncoder(group: 1, 1)).lastInput)
    }

    func testInvalidOrStaleAuthorityCannotCommitRequestedOrActualValue() async throws {
        let (s, d) = fixture()
        s.parameterAuthority = { _ in .reject(actual: .nan, reason: "bad") }
        XCTAssertThrowsError(try s.setAuthorizedParameter("x", to: 100))
        XCTAssertEqual(s.engine.value(of: "x"), 0)
        s
            .parameterAuthority = { _ in
                d.route(9, provenance: .remoteVirtual); return .reject(actual: 10, reason: "old")
            }
        XCTAssertThrowsError(try s.setAuthorizedParameter("x", to: 100))
        XCTAssertEqual(s.engine.value(of: "x"), 0)
    }

    func testAuthorityBatchRejectionDoesNotPartiallyCommitRequestedValues() async throws {
        let (s, _) = fixture()
        s.parameterAuthority = { $0.parameter == "y" ? .reject(actual: 10, reason: "denied") : .accept }
        XCTAssertThrowsError(try s.setAuthorizedParameters([("x", 100), ("y", 100)], identity: .remote))
        XCTAssertEqual(s.engine.value(of: "x"), 0)
        XCTAssertEqual(s.engine.value(of: "y"), 10)
        XCTAssertFalse(s.canUndo)
    }

    func testSameNameEndpointsKeepOriginAndSendSnapshotAcrossSynchronousReconnect() async throws {
        let (s, d) = fixture(); d.route(10, provenance: .remoteVirtual); s.selectSource(.hardware)
        d.onMessages?([.controlChange(channel: 0, number: 1, value: 8)])
        XCTAssertEqual(s.events.first(where: { $0.direction == .input })?.endpoint?.provenance, .remoteVirtual)
        let generation = s.connectionGeneration
        d.onSend = { d.onSend = nil; d.route(11, provenance: .physicalUSB) }
        try s.setAuthorizedParameter("x", to: 64)
        let sent = try XCTUnwrap(s.events.last(where: { $0.delivery == .sent }))
        XCTAssertEqual(sent.endpoint?.endpointID, "10")
        XCTAssertEqual(sent.endpoint?.connectionGeneration, generation)
        XCTAssertEqual(sent.endpoint?.provenance, .remoteVirtual)
        XCTAssertGreaterThan(s.connectionGeneration, generation)
    }

    func testTransportEnvelopeRejectsOldRouteAndDoesNotRelabelReentrantBatch() async throws {
        let (s, d) = fixture(); d.route(10, provenance: .remoteVirtual); s.selectSource(.hardware)
        let old = MIDIEndpointSource(endpointID: "10", connectionGeneration: s.connectionGeneration,
                                     provenance: .remoteVirtual)
        var reconnect = true
        _ = s.observeMonitor { event, _ in
            if event.direction == .input, reconnect {
                reconnect = false; d.route(11, provenance: .physicalUSB)
            }
        }
        d.onInputBatch?(.init(messages: [.controlChange(channel: 0, number: 1, value: 8),
                                         .controlChange(channel: 0, number: 1, value: 9)], endpoint: old))
        let inputs = s.events.filter { $0.direction == .input }
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.endpoint, old)
        let value = s.engine.value(of: "x")
        d.onInputBatch?(.init(messages: [.controlChange(channel: 0, number: 1, value: 99)], endpoint: old))
        XCTAssertEqual(s.engine.value(of: "x"), value)
        XCTAssertTrue(try XCTUnwrap(s.events.last).ignored)
        XCTAssertEqual(s.events.last?.endpoint, old)
    }

    func testAuthorityCallbackRevocationPreventsWholeBatchAndSendCallbackCannotLeakLaterDisplay() async throws {
        let (s, d) = fixture(); s.selectSource(.hardware)
        s.configureParameterWrites(allowsWrite: true, allowsDisplay: true)
        s.parameterAuthority = { request in
            if request.parameter == "y" { s.configureParameterWrites(allowsWrite: false, allowsDisplay: false) }
            return .accept
        }
        XCTAssertThrowsError(try s.setAuthorizedParameters([("x", 64), ("y", 64)], identity: .local))
        XCTAssertEqual(s.engine.value(of: "x"), 0)
        XCTAssertEqual(s.engine.value(of: "y"), 0)
        XCTAssertTrue(d.sent.isEmpty)
        s.parameterAuthority = nil
        s.configureParameterWrites(allowsWrite: true, allowsDisplay: true)
        d.onSend = { s.configureParameterWrites(allowsWrite: false, allowsDisplay: false) }
        try s.setAuthorizedParameters([("x", 64), ("y", 64)], identity: .local)
        XCTAssertEqual(s.engine.value(of: "x"), 64)
        XCTAssertEqual(s.engine.value(of: "y"), 64)
        XCTAssertEqual(d.sent.count, 1)
    }

    func testContextReplacementRejectsPreviouslyGrantedWriteAndClearsQueuedFeedback() async throws {
        let (s, d) = fixture(); s.selectSource(.hardware)
        try s.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        s.configureParameterWrites(allowsWrite: true, allowsDisplay: true)
        try s.setAuthorizedParameter("x", to: 64)
        XCTAssertGreaterThan(s.pendingFeedbackCount, 0)
        d.route(4, provenance: .unknown)
        XCTAssertEqual(s.pendingFeedbackCount, 0)
        XCTAssertThrowsError(try s.setAuthorizedParameter("x", to: 100))
        s.flushFeedback()
        XCTAssertTrue(d.sent.isEmpty)
    }
}
