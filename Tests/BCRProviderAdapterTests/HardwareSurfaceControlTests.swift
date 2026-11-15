import BCRCoreMIDIDriver
import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import BCRProviderMCPAdapter
import Foundation
import SurfaceControlContracts
import XCTest

@MainActor
final class HardwareSurfaceControlTests: XCTestCase {
    func fixture(_ policy: HardwareOutputPolicy = .observe,
                 feedback: Bool = false) throws
        -> (SurfaceSession, ProviderHardwareVisibilityTests.Device, MCPApplicationGateway)
    {
        let device = ProviderHardwareVisibilityTests.Device()
        var map = HardwareMap()
        try map.bind(.pushEncoder(group: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 8))
        try map.bind(.pushEncoder(group: 2, 1), to: .init(kind: .controlChange, channel: 0, number: 19))
        try map.bind(.button(row: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 70), pressMode: .momentary)
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: map,
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     hardwareOutput: policy,
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.selectSource(.hardware)
        let gateway = MCPApplicationGateway(session: session, includeAgent: false)
        try SurfaceControlMCPModule.installHardware(
            on: gateway,
            instanceID: "hardware-test",
            permissions: .init(feedback: feedback)
        )
        return (session, device, gateway)
    }

    func call(_ gateway: MCPApplicationGateway, _ name: String, _ arguments: [String: JSONValue] = [:]) -> JSONValue {
        let result = gateway.call("surface_control_" + name, arguments: .object(arguments))
        XCTAssertFalse(result.isError, "\(result.value)")
        return result.value
    }

    func testRecordedFVCC8And19HardwareOriginsUnknownAndGeneration() throws {
        let (session, device, gateway) = try fixture()
        let d = call(gateway, "discover").objectValue!
        XCTAssertEqual(d["source"], .string("hardware")); XCTAssertEqual(d["contract_version"], .string("1.4"))
        XCTAssertEqual(
            call(gateway, "snapshot", ["instance_id": .string("hardware-test")]).objectValue?["inputs"],
            .object([:])
        )
        device.onMessages?([
            .controlChange(channel: 0, number: 8, value: 45),
            .controlChange(channel: 0, number: 19, value: 61)
        ])
        let page = call(
            gateway,
            "events",
            [
                "instance_id": .string("hardware-test"),
                "epoch": d["expected"]!.objectValue!["epoch"]!,
                "after_sequence": .string("0"),
                "limit": .number(1024)
            ]
        )
        let events = page.objectValue!["events"]!.arrayValue!
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(
            events.map { $0.objectValue!["control_id"]! },
            [.string("pushEncoder.1.1"), .string("pushEncoder.2.1")]
        )
        XCTAssertTrue(events
            .allSatisfy {
                $0.objectValue?["source"] == .string("hardware") && $0.objectValue?["origin"] == .string("hardware")
            })
        session.setParameter("simulation.arm", to: 100)
        XCTAssertEqual(
            call(gateway, "snapshot", ["instance_id": .string("hardware-test")]).objectValue?["latest_sequence"],
            .string("2")
        )
        device.connection = MIDIConnectionSnapshot(); device.onConnection?(device.connection)
        let stale = gateway.call(
            "surface_control_events",
            arguments: .object([
                "instance_id": .string("hardware-test"),
                "epoch": d["expected"]!.objectValue!["epoch"]!,
                "after_sequence": .string("0"),
                "limit": .number(1024)
            ])
        )
        XCTAssertEqual(stale.value.objectValue?["code"], .string("stale_epoch"))
        XCTAssertEqual(
            call(gateway, "snapshot", ["instance_id": .string("hardware-test")]).objectValue?["inputs"],
            .object([:])
        )
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testFeedbackFourCombinationsAndEchoNeverBecomesHardwareInput() throws {
        for policy in [HardwareOutputPolicy.observe, .write] {
            for allowed in [false, true] {
                let (session, device, gateway) = try fixture(policy, feedback: allowed)
                let before = device.sent.count
                let expected = call(gateway, "discover").objectValue!["expected"]!
                let response = gateway.call(
                    "surface_control_feedback",
                    arguments: .object([
                        "expected": expected,
                        "control_id": .string("pushEncoder.1.1"),
                        "kind": .string("value"),
                        "value": .number(64)
                    ])
                )
                if policy == .write && allowed {
                    XCTAssertFalse(response.isError, "\(response.value)"); XCTAssertEqual(device.sent.count - before, 1)
                    device.onMessages?([.controlChange(channel: 0, number: 8, value: 64)])
                    XCTAssertEqual(
                        call(gateway, "snapshot", ["instance_id": .string("hardware-test")])
                            .objectValue?["latest_input_sequence"],
                        .string("0")
                    )
                } else {
                    XCTAssertEqual(response.value.objectValue?["code"], .string("permission_denied")); XCTAssertEqual(
                        device.sent.count,
                        before
                    )
                }
                XCTAssertEqual(session.engine.value(of: "simulation.arm"), 0)
            }
        }
    }

    func testThreeRemoteWritesAreAtomicFixedRejections() throws {
        let (_, _, gateway) = try fixture()
        let expected = call(gateway, "discover").objectValue!["expected"]!
        for (name, arguments, code) in [
            (
                "input",
                [
                    "expected": expected,
                    "expected_sequence": JSONValue.string("0"),
                    "control_id": .string("pushEncoder.1.1"),
                    "encoding": .string("scalar"),
                    "value": .number(10)
                ],
                "permission_denied"
            ),
            (
                "renew",
                ["expected": expected, "control_id": .string("button.1.1"), "hold_s": .double(1)],
                "unsupported_hold"
            ),
            ("reset", ["expected": expected, "expected_sequence": .string("0")], "unsupported_tool")
        ] {
            let response = gateway.call("surface_control_" + name, arguments: .object(arguments))
            XCTAssertTrue(response.isError); XCTAssertEqual(response.value.objectValue?["code"], .string(code))
        }
        XCTAssertEqual(
            call(gateway, "snapshot", ["instance_id": .string("hardware-test")]).objectValue?["latest_sequence"],
            .string("0")
        )
    }

    private struct RejectedObservation: Error {}

    func testJournalRejectedHardwareInputLeavesEngineUnchangedAndIsReportedAsInputFailure() throws {
        let (session, device, _) = try fixture()
        var failures: [SurfaceSessionEvent.Operation] = []
        session.onEvent = { event in if case let .failed(operation, _) = event { failures.append(operation) } }
        let control = BCRControlID.pushEncoder(group: 1, 1)
        let before = session.engine.state(of: control)
        session.hardwareInputPreflight = { _, _ in throw RejectedObservation() }
        device.onMessages?([.controlChange(channel: 0, number: 8, value: 45)])
        XCTAssertEqual(session.engine.state(of: control), before, "Rejected observation changed the engine")
        XCTAssertEqual(failures, [.hardwareInput])
        // Without a refusing hook the next observation commits normally.
        session.hardwareInputPreflight = nil; session.hardwareInputCommit = nil
        device.onMessages?([.controlChange(channel: 0, number: 8, value: 46)])
        XCTAssertEqual(session.engine.state(of: control).value, 46)
        XCTAssertEqual(failures, [.hardwareInput])
    }

    func testRealCoreMIDIQualificationIsOptIn() async throws {
        guard ProcessInfo.processInfo.environment["BCR_E_ATTENDED_HARDWARE"] == "1" else {
            throw XCTSkip(
                "Real CoreMIDI qualification requires an attended supervisor session; E development uses transport doubles only"
            )
        }
        let driver = CoreMIDIService()
        try driver.start()
        for _ in 0 ..< 150 where !driver.connection.isConnected { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(driver.connection.isConnected, "Attended hardware route unavailable")
    }
}
