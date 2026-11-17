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

    func testOldNegativeEnvironmentCannotMutateActualPrimaryOutputOrParameter() throws {
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

    #if os(macOS)
        func testDisabledDiagnosticTapDoesNotEvaluateSerializationArguments() throws {
            if FeedbackJ4Trace.enabled {
                let process = Process(), output = Pipe()
                process
                    .executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
                process.arguments = [
                    "-XCTest",
                    "BCRAgentCoreTests.FeedbackCorePrimaryTests/testDisabledDiagnosticTapDoesNotEvaluateSerializationArguments",
                    Bundle(for: Self.self).bundleURL.path
                ]
                var environment = ProcessInfo.processInfo.environment
                environment.removeValue(forKey: "BCR_J4_SHADOW_ROOT")
                environment.removeValue(forKey: "BCR_J3_SHADOW_ROOT")
                process.environment = environment
                process.standardOutput = output; process.standardError = output
                try process.run(); process.waitUntilExit()
                XCTAssertEqual(
                    process.terminationStatus,
                    0,
                    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                )
                return
            }
            var evaluations = 0
            let recorded = FeedbackJ4Trace.actual(owner: "disabled-probe", operation: "must-not-evaluate",
                                                  input: { evaluations += 1; return ["invalid": Double.nan] }(),
                                                  actual: { evaluations += 1; return ["invalid": Double.infinity] }())
            XCTAssertNil(recorded)
            XCTAssertEqual(evaluations, 0)
        }
    #endif
}
