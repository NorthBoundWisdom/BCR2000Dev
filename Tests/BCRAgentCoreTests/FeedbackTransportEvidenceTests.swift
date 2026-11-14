import BCRAgentCore
import Foundation
import XCTest

@MainActor
final class FeedbackTransportEvidenceTests: XCTestCase {
    private let echo = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 80)
    private let instant = Date(timeIntervalSinceReferenceDate: 1000)

    private func fixture(policy: HardwareOutputPolicy = .write, connected: Bool = true)
        -> (SurfaceSession, OutputRecordingDevice)
    {
        let device = OutputRecordingDevice()
        let instant = instant
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(),
                                     configuration: HardwareOutputPolicyTests.configuration(),
                                     hardwareOutput: policy, now: { instant },
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        if connected { device.connect(1) }
        session.selectSource(.hardware)
        device.sent.removeAll()
        return (session, device)
    }

    // K round T15: failed transport must not invent evidence that a message was sent.
    func testT15FailedTransportDoesNotBecomeFeedbackEchoEvidence() {
        let (session, device) = fixture()
        device.failsSend = true
        session.setParameter("p1", to: 80)
        XCTAssertTrue(device.sent.isEmpty)
        XCTAssertFalse(session.engine.isFeedbackEcho(echo, at: instant))
        device.onMessages?([echo])
        XCTAssertEqual(session.engine.state(of: .encoder(row: 1, 1)).lastInput, 80)
        XCTAssertTrue(session.events.contains { $0.direction == .output && $0.delivery == .failed })
    }

    func testDisconnectedFeedbackDoesNotBecomeEchoEvidence() {
        let (session, device) = fixture(connected: false)
        session.setParameter("p1", to: 80)
        XCTAssertTrue(device.sent.isEmpty)
        XCTAssertFalse(session.engine.isFeedbackEcho(echo, at: instant))
        XCTAssertTrue(session.events.contains { $0.direction == .output && $0.delivery == .disconnected })
    }

    func testObserveSuppressionDoesNotBecomeEchoEvidence() {
        let (session, device) = fixture(policy: .observe)
        session.setParameter("p1", to: 80)
        XCTAssertTrue(device.sent.isEmpty)
        XCTAssertFalse(session.engine.isFeedbackEcho(echo, at: instant))
        device.onMessages?([echo])
        XCTAssertEqual(session.engine.state(of: .encoder(row: 1, 1)).lastInput, 80)
    }

    func testSuccessfulFeedbackRetainsTheSameEchoWindowAndControl() {
        let (session, device) = fixture()
        session.setParameter("p1", to: 80)
        XCTAssertEqual(device.sent, [echo])
        XCTAssertTrue(session.engine.isFeedbackEcho(echo, at: instant))
        XCTAssertTrue(session.engine.isFeedbackEcho(echo, at: instant.addingTimeInterval(0.17)))
        XCTAssertFalse(session.engine.isFeedbackEcho(echo, at: instant.addingTimeInterval(0.19)))
        XCTAssertFalse(session.engine.isFeedbackEcho(.controlChange(channel: 0, number: 82, value: 80), at: instant))
        device.onMessages?([echo])
        XCTAssertNil(session.engine.state(of: .encoder(row: 1, 1)).lastInput)
    }

    func testScheduledEvidenceWaitsForActualDeliveryAndDropsCancelledValues() throws {
        let (session, device) = fixture()
        try session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        session.flushFeedback()
        device.sent.removeAll()
        session.setParameter("p1", to: 80)
        XCTAssertFalse(session.engine.isFeedbackEcho(echo, at: instant))
        device.onMessages?([.controlChange(channel: 0, number: 81, value: 70)])
        session.flushFeedback()
        XCTAssertFalse(device.sent.contains(echo))
        XCTAssertFalse(session.engine.isFeedbackEcho(echo, at: instant))
        session.setParameter("p1", to: 80)
        session.flushFeedback()
        XCTAssertTrue(device.sent.contains(echo))
        XCTAssertTrue(session.engine.isFeedbackEcho(echo, at: instant))
    }

    func testScheduledFailureDoesNotBecomeEchoEvidence() throws {
        let (session, device) = fixture()
        try session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        session.flushFeedback()
        device.sent.removeAll()
        device.failsSend = true
        session.setParameter("p1", to: 80)
        session.flushFeedback()
        XCTAssertTrue(device.sent.isEmpty)
        XCTAssertFalse(session.engine.isFeedbackEcho(echo, at: instant))
    }
}
