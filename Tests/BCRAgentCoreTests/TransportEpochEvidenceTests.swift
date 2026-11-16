import BCRFoundation
import BCRSurfaceDomain
import Foundation
import XCTest

@MainActor
final class TransportEpochEvidenceTests: XCTestCase {
    private final class Device: SurfaceDevice {
        var connection: MIDIConnectionSnapshot = {
            var value = MIDIConnectionSnapshot(connectedSource: "fixture", connectedDestination: "fixture")
            value.connectedSourceID = 1; value.connectedDestinationID = 1
            return value
        }()

        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        var sent: [MIDIVoiceMessage] = []
        var onSend: ((MIDIVoiceMessage) -> Void)?
        var rejectAfterCallback = false
        func send(_ message: MIDIVoiceMessage) throws {
            sent.append(message); onSend?(message)
            if rejectAfterCallback { throw MIDIEncodingError.invalidMessage }
        }

        func route(_ id: Int32?) {
            if let id {
                connection = .init(connectedSource: "fixture", connectedDestination: "fixture")
                connection.connectedSourceID = id; connection.connectedDestinationID = id
            } else { connection = .init() }
            onConnection?(connection)
        }
    }

    private func fixture() -> (SurfaceSession, Device, MIDIVoiceMessage) {
        let device = Device(), control = BCRControlID.pushEncoder(group: 1, 1)
        let midi = MIDIControlID(kind: .controlChange, channel: 2, number: 70)
        let map = HardwareMap(entries: [.init(control: control, midi: midi)])
        let config = SurfaceConfiguration(name: "fixture", parameters: [.init(id: "x", name: "x")],
                                          assignments: [.init(control: control, target: .parameter("x"))])
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: map, configuration: config,
                                     hardwareLifecycleFeedback: false,
                                     now: { Date(timeIntervalSinceReferenceDate: 100) },
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.selectSource(.hardware)
        return (session, device, MIDI1UMPCodec.feedback(control: midi, value: 64))
    }

    func testSynchronousSourceChangeCannotRelabelActualHardwareSendOrItsOriginalControl() async throws {
        let (s, d, message) = fixture()
        let generation = s.inputEvents.generation
        d.onSend = { _ in d.onSend = nil; s.selectSource(.mock) }
        s.setParameter("x", to: 64)
        let sent = try XCTUnwrap(s.events.last { $0.delivery == .sent && $0.message == message })
        XCTAssertEqual(d.sent, [message])
        XCTAssertEqual(sent.source, .hardware)
        XCTAssertEqual(sent.control, .pushEncoder(group: 1, 1))
        XCTAssertEqual(sent.context?.generation, generation)
        XCTAssertEqual(sent.endpoint?.endpointID, "1")
        XCTAssertEqual(s.source, .mock)
    }

    func testInFlightOldRouteAcceptanceCannotRepopulateNewEpochEchoCacheOrConsumeFreshInput() async throws {
        let (s, d, message) = fixture()
        let generation = s.inputEvents.generation
        d.onSend = { _ in d.onSend = nil; d.route(2) }
        s.setParameter("x", to: 64)
        XCTAssertNotEqual(s.inputEvents.generation, generation)
        XCTAssertFalse(s.engine.isFeedbackEcho(message, at: Date(timeIntervalSinceReferenceDate: 100)))
        var accepted = 0
        _ = s.observeAcceptedInput { _, _, _, _ in accepted += 1 }
        d.onMessages?([message])
        XCTAssertEqual(accepted, 1)
        let old = try XCTUnwrap(s.events.first { $0.delivery == .sent && $0.message == message })
        XCTAssertEqual(old.context?.generation, generation)
        XCTAssertEqual(old.endpoint?.endpointID, "1")
        XCTAssertEqual(old.source, .hardware)
    }

    func testOldQueuedFailureCannotSetNewRouteErrorCooldownOrReenqueueOldItems() async throws {
        let (s, d, message) = fixture()
        try s.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128, errorCooldown: 30))
        s.setParameter("x", to: 64)
        XCTAssertEqual(s.pendingFeedbackCount, 1)
        let old = s.inputEvents.generation
        d.onSend = { _ in d.onSend = nil; d.route(2); d.rejectAfterCallback = true }
        s.flushFeedback()
        XCTAssertNotEqual(s.inputEvents.generation, old)
        XCTAssertNil(s.connection.lastError)
        XCTAssertEqual(s.pendingFeedbackCount, 0)
        let failed = try XCTUnwrap(s.events.last { $0.delivery == .failed })
        XCTAssertEqual(failed.message, message)
        XCTAssertEqual(failed.context?.generation, old)
        XCTAssertEqual(failed.endpoint?.endpointID, "1")
        XCTAssertEqual(failed.source, .hardware)
        d.rejectAfterCallback = false
        s.setParameter("x", to: 65)
        s.flushFeedback()
        XCTAssertEqual(d.sent.count, 2)
        XCTAssertEqual(d.sent.last?.dataValue, 65)
        XCTAssertEqual(s.pendingFeedbackCount, 0)
        XCTAssertNil(s.connection.lastError)
    }

    func testPreviouslyAcceptedEchoIsClearedOnRouteChangeAndDisconnectReconnectWithoutSending() async throws {
        for disconnected in [false, true] {
            let (s, d, message) = fixture()
            s.setParameter("x", to: 64)
            XCTAssertTrue(s.engine.isFeedbackEcho(message, at: Date(timeIntervalSinceReferenceDate: 100)))
            let sends = d.sent.count
            let beforeMap = s.learnedHardwareMap, beforeValue = s.engine.value(of: "x")
            if disconnected { d.route(nil) }
            d.route(2)
            XCTAssertEqual(d.sent.count, sends)
            XCTAssertEqual(s.learnedHardwareMap, beforeMap)
            XCTAssertEqual(s.engine.value(of: "x"), beforeValue)
            XCTAssertFalse(s.engine.isFeedbackEcho(message, at: Date(timeIntervalSinceReferenceDate: 100)))
            var accepted = 0
            _ = s.observeAcceptedInput { _, _, _, _ in accepted += 1 }
            d.onMessages?([message])
            XCTAssertEqual(accepted, 1)
        }
    }
}
