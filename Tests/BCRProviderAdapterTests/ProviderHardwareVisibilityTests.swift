import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import BCRProviderApplication
import BCRProviderMCPAdapter
import Foundation
import XCTest

@MainActor
final class ProviderHardwareVisibilityTests: XCTestCase {
    final class Device: SurfaceDevice {
        var connection = MIDIConnectionSnapshot(
            connectedSource: "test-input",
            connectedDestination: "test-output",
            lastError: nil
        )
        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        var sent: [MIDIVoiceMessage] = []
        func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
    }

    func testProviderWritesReportDeliveryThroughExistingConsoleJournal() throws {
        for policy in [HardwareOutputPolicy.observe, .write] {
            let device = Device()
            let session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(),
                                         configuration: .init(name: "test", parameters: [
                                             .init(id: "p", name: "p", group: "test", defaultValue: 10)
                                         ], assignments: [.init(
                                             control: .encoder(row: 1, 1),
                                             target: .parameter("p")
                                         )]),
                                         hardwareOutput: policy, saveHardwareMap: { _ in }, saveConfiguration: { _ in })
            session.selectSource(.hardware)
            let gateway = MCPApplicationGateway(session: session, includeAgent: false)
            try ProviderMCPModule.install(on: gateway, application: ProviderApplication(configuration: .init()))
            for (name, args) in [
                ("set_parameter", ["id": JSONValue.string("p"), "value": .number(20)]),
                ("nudge_parameter", ["id": .string("p"), "delta": .number(1)]),
                ("set_parameters", ["values": .array([.object(["id": .string("p"), "value": .number(22)])])]),
                ("reset_group", ["group": .string("test")])
            ] {
                let mark = session.inputEvents.sequence
                let before = device.sent.count
                let result = gateway.call(name, arguments: .object(args))
                XCTAssertFalse(result.isError, "\(name): \(result.value)")
                let journal = gateway.call("console_events", arguments: .object([
                    "schema_version": .number(1), "generation": .string(session.inputEvents.generation),
                    "after_sequence": .number(mark)
                ]))
                XCTAssertFalse(journal.isError)
                let text = try journal.value.jsonText
                XCTAssertTrue(text.contains(policy == .observe ? "feedback.suppressed" : "feedback.sent"), text)
                XCTAssertEqual(device.sent.count - before, policy == .observe ? 0 : 1)
            }
            let mark = session.inputEvents.sequence
            session.synchronize()
            let journal = try session.inputEvents.read(generation: session.inputEvents.generation, after: mark)
            XCTAssertTrue(try journal.jsonText.contains(policy == .observe ? "feedback.suppressed" : "feedback.sent"))
        }
    }
}
