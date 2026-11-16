import BCRFoundation
import BCRMCPAdapter
import BCRProviderMCPAdapter
import BCRSurfaceDomain
import Foundation
import SurfaceControlContracts
import XCTest

@MainActor
final class OwnedVirtualProfileTests: XCTestCase {
    func fixture() -> (SurfaceSession, ProviderHardwareVisibilityTests.Device) {
        let device = ProviderHardwareVisibilityTests.Device()
        let control = BCRControlID.encoder(row: 1, 1)
        let session = SurfaceSession(hardwareDevice: device,
                                     hardwareMap: .init(entries: [.init(
                                         control: control,
                                         midi: .init(kind: .controlChange, channel: 0, number: 81)
                                     )]),
                                     configuration: .init(name: "fixture"), hardwareLifecycleFeedback: false,
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.selectSource(.hardware)
        return (session, device)
    }

    func testModeIsExplicitDistinctAndRetentionStaysIndependent() async throws {
        let (surface, device) = fixture()
        let regular = try BCRHardwareSurfaceControlAdapter.publishedContract(surface: surface)
        let rehearsal = try BCRHardwareSurfaceControlAdapter.publishedContract(
            surface: surface,
            mode: .ownedVirtualRehearsal
        )
        let retained = try BCRHardwareSurfaceControlAdapter.publishedContract(
            surface: surface,
            inputEventCapacity: 2,
            mode: .ownedVirtualRehearsal
        )
        XCTAssertEqual(regular.value(for: "discovery")?.value(for: "contract_version"), .string("1.4"))
        XCTAssertEqual(rehearsal.value(for: "discovery")?.value(for: "contract_version"), .string("1.5"))
        XCTAssertEqual(
            rehearsal.value(for: "discovery")?.value(for: "profile")?.value(for: "id"),
            .string("bcr2000.owned-virtual-rehearsal")
        )
        XCTAssertEqual(regular.value(for: "tools")?.arrayValue?.count, 7)
        XCTAssertEqual(rehearsal.value(for: "tools")?.arrayValue?.count, 7)
        XCTAssertEqual(retained.value(for: "tools")?.arrayValue?.count, 8)
        let capabilities = rehearsal.value(for: "discovery")!.value(for: "profile")!.value(for: "capabilities")!
            .arrayValue!
        XCTAssertTrue(capabilities.contains(.string("session.owned_virtual_rehearsal")))
        XCTAssertFalse(capabilities.contains(.string("events.input_retention")))
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testEveryHardwareRebuildKeepsNonphysicalModeAndCapacityWithoutSending() async throws {
        let (surface, device) = fixture()
        let gateway = MCPApplicationGateway(session: surface, includeAgent: false)
        try SurfaceControlMCPModule.installHardware(on: gateway, instanceID: "owned-mode",
                                                    inputEventCapacity: 2, hardwareMode: .ownedVirtualRehearsal)
        let first = gateway.call("surface_control_discover").value
        device.connection = .init(); device.onConnection?(device.connection)
        let next = gateway.call("surface_control_discover").value
        XCTAssertNotEqual(first.value(for: "expected"), next.value(for: "expected"))
        XCTAssertEqual(next.value(for: "profile")?.value(for: "id"), .string("bcr2000.owned-virtual-rehearsal"))
        let page = gateway.call("surface_control_input_events", arguments: .object([
            "expected": next.value(for: "expected")!, "after_input_sequence": .string("0"), "limit": .number(128)
        ]))
        XCTAssertFalse(page.isError)
        XCTAssertEqual(page.value.value(for: "input_event_capacity"), .number(2))
        XCTAssertEqual(page.value.value(for: "events"), .array([]))
        XCTAssertTrue(device.sent.isEmpty)
    }
}
