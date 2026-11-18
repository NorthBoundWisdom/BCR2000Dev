import BCRFoundation
@testable import BCRSurfaceDomain
import Foundation
import XCTest

@MainActor
final class FeedbackCorePrimaryTests: XCTestCase {
    private final class Device: SurfaceDevice {
        var connection: MIDIConnectionSnapshot = {
            var value = MIDIConnectionSnapshot(connectedSource: "fixture", connectedDestination: "fixture")
            value.connectedSourceID = 1; value.connectedDestinationID = 1
            return value
        }()

        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        var sent: [MIDIVoiceMessage] = []
        func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
    }

    func testOldNegativeEnvironmentCannotMutateActualPrimaryOutputOrParameter() async throws {
        let prior = ProcessInfo.processInfo.environment["BCR_J4_NEGATIVE_PHASE"]
        defer {
            if let prior { setenv("BCR_J4_NEGATIVE_PHASE", prior, 1) }
            else { unsetenv("BCR_J4_NEGATIVE_PHASE") }
        }
        let control = BCRControlID.encoder(row: 1, 1)
        let message = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 64)
        for phase in ["capture", "dispatch", "authorization", "preflight", "receipt", "summary"] {
            setenv("BCR_J4_NEGATIVE_PHASE", phase, 1)
            let device = Device()
            let map = HardwareMap(entries: [.init(control: control, midi: message.controlID)])
            let configuration = SurfaceConfiguration(name: "primary-inert-env", parameters: [.init(id: "p", name: "p")],
                                                     assignments: [.init(control: control, target: .parameter("p"))])
            let session = SurfaceSession(hardwareDevice: device, hardwareMap: map, configuration: configuration,
                                         hardwareLifecycleFeedback: false,
                                         now: { Date(timeIntervalSinceReferenceDate: 1000) },
                                         saveHardwareMap: { _ in }, saveConfiguration: { _ in })
            session.selectSource(.hardware)
            try session.setHardwareDisplayFeedback(control, rawValue: 64)
            XCTAssertEqual(device.sent, [message], phase)
            XCTAssertEqual(session.engine.value(of: "p"), 0, phase)
            let inputs = session.inputEvents.snapshot().objectValue?["events"]?.arrayValue?
                .filter { $0.objectValue?["kind"]?.stringValue == "control.input" } ?? []
            XCTAssertTrue(inputs.isEmpty, phase)
        }
    }
}
