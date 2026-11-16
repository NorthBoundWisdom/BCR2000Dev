import BCRFoundation
import BCRMCPAdapter
import BCRProviderMCPAdapter
import BCRSurfaceDomain
import Foundation
import XCTest

/// Same ordered native fixture as Release rehearsal, using unchanged 2915 Session/Engine blobs.
@MainActor
final class RetainedOverlayGenerationTests: XCTestCase {
    func testNewActualInputReplansRetainedDesiredDisplayWithoutOldQueueEchoOrLifecycleReplay() async throws {
        let device = ProviderHardwareVisibilityTests.Device(), control = BCRControlID.encoder(row: 1, 1)
        let time = Date(timeIntervalSinceReferenceDate: 100)
        let map = HardwareMap(entries: [.init(
            control: control,
            midi: .init(kind: .controlChange, channel: 0, number: 81)
        )])
        let configuration = SurfaceConfiguration(
            name: "fixture",
            parameters: [.init(id: "axis", name: "Axis", maximum: 127)],
            assignments: [.init(control: control, target: .parameter("axis"))]
        )
        let surface = SurfaceSession(hardwareDevice: device, hardwareMap: map, configuration: configuration,
                                     hardwareOutput: .write, hardwareLifecycleFeedback: false,
                                     now: { time }, saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        surface.selectSource(.hardware)
        let gateway = MCPApplicationGateway(session: surface, includeAgent: false)
        try SurfaceControlMCPModule.installHardware(
            on: gateway,
            instanceID: "original-overlay",
            permissions: .init(feedback: true)
        )
        device.onMessages?([.controlChange(channel: 0, number: 81, value: 45)])
        XCTAssertEqual(surface.engine.value(of: "axis"), 45)
        let old = gateway.call("surface_control_discover").value
        let update = gateway.call("surface_control_feedback", arguments: .object([
            "expected": old.value(for: "expected")!, "control_id": .string("encoder.1.1"), "kind": .string("value"),
            "value": .number(64)
        ]))
        XCTAssertFalse(update.isError)
        XCTAssertEqual(surface.engine.value(of: "axis"), 45)
        XCTAssertEqual(device.sent.map(\.dataValue), [64])
        let oldEpoch = surface.inputEvents.generation
        device.connection = .init(); device.onConnection?(device.connection)
        device.connection = .init(connectedSource: "fixture", connectedDestination: "fixture")
        device.connection.connectedSourceID = 77; device.connection.connectedDestinationID = 78
        device.onConnection?(device.connection)
        let newEpoch = surface.inputEvents.generation, newGeneration = surface.connectionGeneration
        XCTAssertNotEqual(oldEpoch, newEpoch)
        XCTAssertEqual(device.sent.map(\.dataValue), [64])
        XCTAssertEqual(surface.pendingFeedbackCount, 0)
        let message = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 64)
        XCTAssertFalse(surface.engine.isFeedbackEcho(message, at: time))
        let empty = gateway.call(
            "surface_control_snapshot",
            arguments: .object(["instance_id": .string("original-overlay")])
        ).value
        XCTAssertEqual(empty.value(for: "inputs"), .object([:]))
        XCTAssertEqual(empty.value(for: "feedback"), .object([:]))
        device.onMessages?([.controlChange(channel: 0, number: 81, value: 46)])
        XCTAssertEqual(surface.engine.value(of: "axis"), 46)
        XCTAssertEqual(device.sent.map(\.dataValue), [64, 64])
        let currentPlan = try XCTUnwrap(surface.events.last { $0.delivery == .sent })
        XCTAssertEqual(currentPlan.context?.generation, newEpoch)
        XCTAssertEqual(currentPlan.endpoint?.connectionGeneration, newGeneration)
        XCTAssertEqual(currentPlan.endpoint?.endpointID, "78")
        XCTAssertEqual(currentPlan.source, .hardware)
        XCTAssertEqual(currentPlan.origin, .software) // New actual-input effect, not the older remote display request.
        XCTAssertEqual(surface.pendingFeedbackCount, 0)
        let current = gateway.call(
            "surface_control_snapshot",
            arguments: .object(["instance_id": .string("original-overlay")])
        ).value
        XCTAssertEqual(current.value(for: "latest_input_sequence"), .string("1"))
        XCTAssertEqual(current.value(for: "inputs")?.value(for: "encoder.1.1"), .number(46))
        XCTAssertEqual(current.value(for: "feedback"), .object([:]))
    }
}
