import BCRAgentCore
import Foundation
import XCTest

@MainActor
final class SharedSurfaceRegressionTests: XCTestCase {
    func testT03InputOnlyGeneratesFeedbackForOtherMappedControl() {
        let device = OutputRecordingDevice()
        let a = BCRControlID.encoder(row: 1, 1), b = BCRControlID.encoder(row: 1, 2)
        let session = SurfaceSession(hardwareDevice: device, configuration: .init(
            name: "Independent feedback projection",
            parameters: [.init(id: "p", name: "P", maximum: 127)],
            assignments: [.init(control: a, target: .parameter("p")), .init(control: b, target: .parameter("p"))]
        ), saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.turn(a, by: 20)
        let input = session.events.filter { $0.direction == .input }
        let output = session.events.filter { $0.direction == .output }
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(output.count, 1)
        XCTAssertNotEqual(input.first?.message.controlID, output.first?.message.controlID)
        XCTAssertEqual(output.first?.control, b)
        XCTAssertEqual(session.engine.value(of: "p"), 20)
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testT12SameEndpointReconnectDiscardsOldQueuedOutput() throws {
        let device = OutputRecordingDevice()
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(),
                                     configuration: HardwareOutputPolicyTests.configuration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        device.connect(1)
        session.selectSource(.hardware)
        try session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        session.flushFeedback()
        device.sent.removeAll()
        let generation = session.inputEvents.generation
        session.setParameter("p1", to: 98)
        XCTAssertGreaterThan(session.pendingFeedbackCount, 0)
        device.connect(nil)
        XCTAssertEqual(session.pendingFeedbackCount, 0)
        session.setParameter("p1", to: 77)
        device.connect(1) // Same endpoint identities, a new connection lifetime.
        session.flushFeedback()
        XCTAssertNotEqual(session.inputEvents.generation, generation)
        XCTAssertEqual(device.sent.map(\.midi1Bytes), [[176, 81, 77], [176, 82, 20], [176, 83, 30]])
        XCTAssertFalse(device.sent.contains { $0.dataValue == 98 })
    }
}
