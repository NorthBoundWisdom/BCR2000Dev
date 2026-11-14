import BCRAgentCore
import Foundation
import XCTest

/// Records every attempted device message without opening CoreMIDI.
@MainActor
final class OutputRecordingDevice: SurfaceDevice {
    var connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    var failsSend = false
    func send(_ message: MIDIVoiceMessage) throws {
        if failsSend { throw NSError(domain: "recording-device", code: 1) }
        sent.append(message)
    }

    func connect(_ route: Int?) {
        connection = route.map { _ in
            MIDIConnectionSnapshot(connectedSource: "recording-input", connectedDestination: "recording-output",
                                   lastError: nil)
        } ?? MIDIConnectionSnapshot()
        connection.connectedSourceID = route.map(Int32.init)
        connection.connectedDestinationID = route.map(Int32.init)
        onConnection?(connection)
    }
}

@MainActor
final class HardwareOutputPolicyTests: XCTestCase {
    static func configuration() -> SurfaceConfiguration {
        SurfaceConfiguration(name: "Output recording", parameters: (1 ... 3).map {
            ParameterDefinition(id: ParameterID("p\($0)"), name: "P\($0)", minimum: 0,
                                maximum: 127, defaultValue: Double($0 * 10))
        }, assignments: (1 ... 3).map {
            ControlAssignment(control: .encoder(row: 1, $0), target: .parameter(ParameterID("p\($0)")))
        })
    }

    static func exercise(_ session: SurfaceSession, device: OutputRecordingDevice) throws {
        session.selectSource(.hardware)
        device.connect(1)
        for index in 1 ... 3 { session.setParameter(ParameterID("p\(index)"), to: Double(index * 11)) }
        try session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        session.flushFeedback()
        session.synchronize()
        session.flushFeedback()
        device.connect(nil)
        device.connect(2)
        session.flushFeedback()
        session.setParameter("p1", to: 99)
        session.flushFeedback()
    }

    // Recorded on the unmodified 5564f174730af36021d233241925ed40a7a1e095 product sources;
    // unchanged on 1a6ad3b279d3beaf128c9b57f7339a715a5ee1ba.
    private let originalWriteBytes: [[UInt8]] = [
        [176, 81, 10], [176, 82, 20], [176, 83, 30], [176, 81, 11], [176, 82, 22], [176, 83, 33],
        [176, 81, 11], [176, 82, 22], [176, 83, 33], [176, 81, 11], [176, 82, 22], [176, 83, 33],
        [176, 81, 11], [176, 82, 22], [176, 83, 33], [176, 81, 99]
    ]

    func testWriteAndUnspecifiedSessionPolicyMatchOriginalByteSequence() throws {
        for explicit in [false, true] {
            let device = OutputRecordingDevice()
            let session: SurfaceSession
            if explicit {
                session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(),
                                         configuration: Self.configuration(), hardwareOutput: .write,
                                         now: { Date(timeIntervalSinceReferenceDate: 1000) },
                                         saveHardwareMap: { _ in }, saveConfiguration: { _ in })
            } else {
                session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(),
                                         configuration: Self.configuration(),
                                         now: { Date(timeIntervalSinceReferenceDate: 1000) },
                                         saveHardwareMap: { _ in }, saveConfiguration: { _ in })
            }
            try Self.exercise(session, device: device)
            XCTAssertEqual(device.sent.map(\.midi1Bytes), originalWriteBytes)
        }
    }

    func testObserveSuppressesAllFeedbackButContinuesAcceptingHardwareInput() throws {
        let device = OutputRecordingDevice()
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(),
                                     configuration: Self.configuration(), hardwareOutput: .observe,
                                     now: { Date(timeIntervalSinceReferenceDate: 1000) },
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        try Self.exercise(session, device: device)
        try session.replaceConfiguration(Self.configuration())
        session.bindIndicator("test.indicator", to: .parameter("p1"))
        session.setIndicatorFeedback("test.indicator", value: 72)
        session.synchronize()
        session.flushFeedback()
        let raw = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 10)
        device.onMessages?([raw]) // Even the value of suppressed feedback remains a real input.
        XCTAssertEqual(session.engine.value(of: "p1"), 10)
        XCTAssertEqual(session.engine.state(of: .encoder(row: 1, 1)).lastInput, 10)
        XCTAssertTrue(device.sent.isEmpty)
        let outputs = session.events.filter { $0.direction == .output }
        XCTAssertFalse(outputs.isEmpty)
        XCTAssertTrue(outputs.allSatisfy { $0.ignored && $0.delivery == .suppressed })
        XCTAssertEqual(session.pendingFeedbackCount, 0)
        session.selectSource(.mock)
        session.setParameter("p2", to: 50)
        XCTAssertEqual(session.mock.value(of: .encoder(row: 1, 2)), 50)
        session.selectSource(.hardware)
        session.synchronize()
        XCTAssertTrue(device.sent.isEmpty, "Runtime source switching cannot grant device output")
    }
}
