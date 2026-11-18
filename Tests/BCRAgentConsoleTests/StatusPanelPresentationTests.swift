import AppKit
import BCRFoundation
import BCRConfigurationAdapter
import BCRCoreMIDIDriver
import BCRSurfaceDomain
import BCRMCPAdapter
import BCRProviderMCPAdapter
import BCRTimingTestSupport
import SwiftUI
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class PanelMIDI: MIDIService {
    var connection = MIDIConnectionSnapshot(
        connectedSource: "TEST ONLY input",
        connectedDestination: "TEST ONLY output"
    )
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    func start() throws { onConnection?(connection) }
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
}

@MainActor
final class StatusPanelPresentationTests: XCTestCase {
    private func render(_ model: ConsoleViewModel, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["BCR_PANEL_RENDER_OUTPUT"] else { return }
        _ = NSApplication.shared
        let view = NSHostingView(rootView: SurfacePanelView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 755)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appending(path: name + ".png"), options: .withoutOverwriting)
    }

    private func verify(hardware: Bool) async throws {
        let stores = ConsoleStores.temporary()
        try stores.hardwareMap.save(HardwareMap.mockPreset())
        try stores.configuration.save(SurfaceControlMCPModule.simulationConfiguration())
        let midi = PanelMIDI()
        let model = ConsoleViewModel(stores: stores, startsMIDI: hardware, midiService: midi,
                                     automaticallyAdvancesMock: false, timing: .immediate)
        let gateway = model.mcp.service
        let session = try XCTUnwrap(gateway.surfaceSession)
        gateway.permissions.parameterWrite = true
        let name = hardware ? "hardware" : "simulation"
        var confirmedBaseline = 0
        if hardware {
            try await waitUntil("fake MIDI startup") { !model.startingMIDI }
            XCTAssertTrue(midi.sent.isEmpty)
            model.requestSource(.hardware)
            try await waitUntil("explicit GUI connection confirmation") { model.pendingHardwareConnection != nil }
            XCTAssertTrue(midi.sent.isEmpty, "The real GUI confirmation boundary must not send before confirmation")
            model.connectHardware(try XCTUnwrap(model.pendingHardwareConnection).id, mode: .write)
            try await model.waitForBackgroundWork()
            confirmedBaseline = midi.sent.count
            XCTAssertEqual(
                confirmedBaseline,
                8,
                "Existing explicit local synchronization, not headless lifecycle output"
            )
            XCTAssertEqual(model.source, .hardware)
            try SurfaceControlMCPModule.installHardware(
                on: gateway,
                instanceID: "panel",
                permissions: .init(feedback: true)
            )
        } else {
            try SurfaceControlMCPModule.install(on: gateway, instanceID: "panel", permissions: .init(feedback: true))
        }
        // This is a test-only installation of the existing adapter on the actual VM's one session.
        // The default GUI does not expose the surface-control endpoint or the CLI demo.
        XCTAssertTrue(gateway.surfaceSession === session)
        XCTAssertEqual(midi.sent.count, confirmedBaseline)
        let discovery = gateway.call("surface_control_discover").value
        let expected = try XCTUnwrap(discovery.objectValue?["expected"])
        let initial = session.engine.value(of: "simulation.arm")
        let slots = model.slots.map(\.state)
        try render(model, name: name + "-before")
        func feedback(_ id: String, kind: String = "value", _ value: JSONValue) {
            let reply = gateway.call("surface_control_feedback", arguments: .object([
                "expected": expected, "control_id": .string(id), "kind": .string(kind), "value": value
            ]))
            XCTAssertFalse(reply.isError)
        }
        for (index, value) in [0, 25, 50, 75, 100, 127].enumerated() {
            feedback("pushEncoder.1.\(index + 1)", .number(value))
        }
        feedback("pushEncoder.1.7", .number(96))
        feedback("pushEncoder.1.8", .number(32))
        feedback("encoder.1.1", .number(64))
        feedback("button.1.1", kind: "indicator", .string("on"))
        try await model.waitForBackgroundWork()
        try await waitUntil("panel feedback") { model.presentation(of: .pushEncoder(group: 1, 6)).value == 127 }
        XCTAssertEqual(model.presentation(of: .pushEncoder(group: 1, 6)).ringLEDs, [14])
        XCTAssertEqual(model.presentation(of: .encoder(row: 1, 1)).value, 64)
        XCTAssertEqual(model.presentation(of: .encoder(row: 1, 1)).ringLEDs, [7])
        XCTAssertTrue(BCRButtonLED.isLit(model.presentation(of: .button(row: 1, 1)).value))
        XCTAssertFalse(model.presentation(of: .button(row: 1, 1)).hardwarePressed)
        XCTAssertEqual(session.engine.value(of: "simulation.arm"), initial)
        XCTAssertEqual(model.slots.map(\.state), slots)
        let snapshot = gateway.call("surface_control_snapshot", arguments: .object(["instance_id": .string("panel")]))
            .value
        XCTAssertEqual(snapshot.objectValue?["latest_input_sequence"], .string("0"))
        try render(model, name: name + "-active")
        feedback("button.1.1", kind: "indicator", .string("off"))
        for index in 1 ... 8 { feedback("pushEncoder.1.\(index)", .number(0)) }
        feedback("encoder.1.1", .number(0))
        try await model.waitForBackgroundWork()
        try await waitUntil("freshness off") { model.presentation(of: .button(row: 1, 1)).value == 0 }
        XCTAssertFalse(BCRButtonLED.isLit(model.presentation(of: .button(row: 1, 1)).value))
        XCTAssertEqual(model.presentation(of: .pushEncoder(group: 1, 6)).ringLEDs, [0]) // Rest is not darkness.
        XCTAssertEqual(session.engine.value(of: "simulation.arm"), initial)
        XCTAssertEqual(model.slots.map(\.state), slots)
        XCTAssertEqual(midi.sent.count - confirmedBaseline, hardware ? 20 : 0)
        try render(model, name: name + "-rest")
        model.provider.stopClock()
    }

    func testSimulationFeedbackReachesActualVirtualPanelPresentationWithoutInput() async throws {
        try await verify(hardware: false)
    }

    func testFakeHardwareFeedbackReachesActualVirtualPanelPresentationWithoutInput() async throws {
        try await verify(hardware: true)
    }
}
