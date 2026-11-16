import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import BCRProviderApplication
import BCRProviderMCPAdapter
import Foundation
import XCTest

/// New G6 baselines recorded before changing any feedback production code.
@MainActor
final class FeedbackPathGoldenTests: XCTestCase {
    private func fixture() throws -> (SurfaceSession, ProviderHardwareVisibilityTests.Device, MCPApplicationGateway) {
        let device = ProviderHardwareVisibilityTests.Device()
        var map = HardwareMap()
        try map.bind(.encoder(row: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 81))
        let configuration = SurfaceConfiguration(name: "Golden", parameters: [
            .init(id: "p", name: "p", group: "test", minimum: 0, maximum: 127, defaultValue: 10)
        ], assignments: [.init(control: .encoder(row: 1, 1), target: .parameter("p"))])
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: map, configuration: configuration,
                                     hardwareOutput: .write, hardwareLifecycleFeedback: false,
                                     now: { Date(timeIntervalSinceReferenceDate: 1000) },
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.selectSource(.hardware)
        try session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        return (session, device, MCPApplicationGateway(session: session, includeAgent: false))
    }

    func testRecordedProviderAndHardwareDisplaySequences() async throws {
        var output: [String: [[UInt8]]] = [:]
        do {
            let (session, device, gateway) = try fixture()
            try ProviderMCPModule.install(on: gateway, application: ProviderApplication(configuration: .init()))
            for (name, arguments) in [
                ("set_parameter", ["id": JSONValue.string("p"), "value": .number(20)]),
                ("nudge_parameter", ["id": .string("p"), "delta": .number(1)]),
                ("set_parameters", ["values": .array([.object(["id": .string("p"), "value": .number(22)])])]),
                ("reset_group", ["group": .string("test")])
            ] {
                XCTAssertFalse(gateway.call(name, arguments: .object(arguments)).isError)
                session.flushFeedback()
            }
            output["provider_1_parameter_feedback"] = device.sent.map(\.midi1Bytes)
        }
        do {
            let (session, device, gateway) = try fixture()
            try SurfaceControlMCPModule.installHardware(
                on: gateway,
                instanceID: "golden",
                permissions: .init(feedback: true)
            )
            let discovery = gateway.call("surface_control_discover", arguments: .object([:]))
            XCTAssertFalse(discovery.isError)
            let expected = try XCTUnwrap(discovery.value.objectValue?["expected"])
            for value in [0, 64, 127] {
                let result = gateway.call("surface_control_feedback", arguments: .object([
                    "expected": expected, "control_id": .string("encoder.1.1"), "kind": .string("value"),
                    "value": .number(value)
                ]))
                XCTAssertFalse(result.isError, "\(result.value)")
                XCTAssertEqual(session.pendingFeedbackCount, 0)
            }
            output["hardware_14_explicit_display"] = device.sent.map(\.midi1Bytes)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let captured = try encoder.encode(output)
        if let path = ProcessInfo.processInfo.environment["BCR_G6_CAPTURE_PROVIDER"] {
            try captured.write(to: URL(fileURLWithPath: path))
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FeedbackOutput/g6-provider.json")
        let golden = try JSONDecoder().decode([String: [[UInt8]]].self, from: Data(contentsOf: path))
        XCTAssertEqual(output, golden)
    }
}
