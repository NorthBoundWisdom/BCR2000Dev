import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import BCRProviderMCPAdapter
import Foundation
import SurfaceControlContracts
import XCTest

@MainActor
final class NeutralEpochInjectionTests: XCTestCase {
    private final class Sequence {
        var value = 0; func next() -> String { value += 1; return "injected-epoch.\(value)" }
    }

    private final class Device: SurfaceDevice {
        var connection = MIDIConnectionSnapshot(connectedSource: "fixture", connectedDestination: "fixture")
        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        func send(_ message: MIDIVoiceMessage) throws {}
    }

    func testSimulationEpochFactoryIsUsedOnContextResetAndDefaultRemainsUUID() async throws {
        let sequence = Sequence()
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: session)
        let adapter = try BCRSurfaceControlAdapter(surface: session, instanceID: "fixture", monotonic: { 10 },
                                                   epochFactory: { sequence.next() })
        let old = try adapter.discovery().expected
        XCTAssertEqual(old.epoch, "injected-epoch.1")
        try session.replaceConfiguration(SurfaceControlMCPModule.simulationConfiguration())
        let new = try adapter.discovery().expected
        XCTAssertEqual(new.epoch, "injected-epoch.2")
        XCTAssertEqual(sequence.value, 2)
        XCTAssertThrowsError(try adapter.execute(
            .feedback(.init(expected: old, controlID: "pushEncoder.1.1", kind: "value", value: .number(1))),
            gateway: gateway
        ))
        let ordinary = try BCRSurfaceControlAdapter(surface: session, instanceID: "ordinary")
        XCTAssertNotNil(UUID(uuidString: try ordinary.discovery().expected.epoch))
    }

    func testHardwareEpochFactoryRechecksOriginalExpectedAfterRouteChange() async throws {
        let sequence = Sequence(), device = Device()
        let session = SurfaceSession(
            hardwareDevice: device,
            hardwareMap: .mockPreset(),
            hardwareLifecycleFeedback: false,
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        session.selectSource(.hardware)
        let gateway = MCPApplicationGateway(session: session)
        let adapter = try BCRHardwareSurfaceControlAdapter(
            surface: session,
            instanceID: "fixture",
            permissions: .init(feedback: true),
            monotonic: { 10 },
            epochFactory: { sequence.next() }
        )
        let discovery = try adapter.execute(.discover, gateway: gateway)
        let old = try discovery.objectValue!["expected"]!.decoded(ControlExpected.self)
        XCTAssertEqual(old.epoch, "injected-epoch.2")
        device.connection.connectedSourceID = 10
        device.onConnection?(device.connection)
        let current = try adapter.execute(.discover, gateway: gateway)
        XCTAssertEqual(current.objectValue?["expected"]?.objectValue?["epoch"], .string("injected-epoch.3"))
        XCTAssertEqual(sequence.value, 3)
        XCTAssertThrowsError(try adapter.execute(
            .feedback(.init(expected: old, controlID: "pushEncoder.1.1", kind: "value", value: .number(1))),
            gateway: gateway
        ))
    }
}
