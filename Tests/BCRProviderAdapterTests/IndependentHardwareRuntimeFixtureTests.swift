import BCRFoundation
import BCRProviderMCPAdapter
import BCRSurfaceDomain
import BCRMCPAdapter
import Foundation
import SurfaceControlContracts
import SurfacePluginContracts
import XCTest

/// Runs the independent shared fixture through the actual host adapter/engine/fake output exit.
@MainActor
final class IndependentHardwareRuntimeFixtureTests: XCTestCase {
    final class Clock { var time: Double = 0 }
    final class Device: SurfaceDevice {
        var connection = MIDIConnectionSnapshot(
            connectedSource: "TEST ONLY input",
            connectedDestination: "TEST ONLY output",
            lastError: nil
        )
        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        var failsSend = false
        var accepted: [MIDIVoiceMessage] = []
        var attempts = 0
        func send(_ message: MIDIVoiceMessage) throws {
            attempts += 1
            if failsSend { throw NSError(domain: "test-only-display-rejection", code: 1) }
            accepted.append(message)
        }
    }

    func testIndependentFixtureUsesRealIgnoredButtonAndDisplayFailurePaths() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = try JSONSerialization
            .jsonObject(with: Data(contentsOf: root
                    .appendingPathComponent(
                        "build/seed/SurfacePlugins/fixtures/surface-control-hardware-independent-v1.4.json"
                    ))) as! [String: Any]
        let roles = ["button_ignored": "button.1.1", "input_a": "pushEncoder.1.1",
                     "feedback_progress": "pushEncoder.1.2", "input_only": "button.1.2"]
        XCTAssertEqual(Set(roles.values).count, roles.count)
        var executed: [String: Int] = [:]
        var skipped: [String: Int] = [:]
        for scene in fixture["scenarios"] as! [[String: Any]] {
            let name = scene["id"] as! String
            let steps = scene["steps"] as! [[String: Any]]
            let required = scene["required_roles"] as! [String]
            guard required.allSatisfy({ roles[$0] != nil }) else { skipped[name] = steps.count; continue }
            let device = Device(), clock = Clock()
            let entries = [
                HardwareMapEntry(
                    control: .pushEncoder(group: 1, 1),
                    midi: .init(kind: .controlChange, channel: 0, number: 8)
                ),
                HardwareMapEntry(
                    control: .pushEncoder(group: 1, 2),
                    midi: .init(kind: .controlChange, channel: 0, number: 9)
                ),
                HardwareMapEntry(
                    control: .button(row: 1, 1),
                    midi: .init(kind: .controlChange, channel: 0, number: 70),
                    visualizationOnly: true,
                    pressMode: .momentary
                ),
                HardwareMapEntry(
                    control: .button(row: 1, 2),
                    midi: .init(kind: .controlChange, channel: 0, number: 71),
                    visualizationOnly: true,
                    pressMode: .momentary
                )
            ]
            let map = HardwareMap(entries: entries)
            let surface = SurfaceSession(hardwareDevice: device, hardwareMap: map, hardwareOutput: .write,
                                         now: { Date(timeIntervalSinceReferenceDate: clock.time) },
                                         saveHardwareMap: { _ in }, saveConfiguration: { _ in })
            surface.selectSource(.hardware)
            let gateway = MCPApplicationGateway(session: surface, includeAgent: false)
            let adapter = try BCRHardwareSurfaceControlAdapter(surface: surface, instanceID: "independent-bcr",
                                                               permissions: .init(feedback: true),
                                                               eventCapacity: scene["event_capacity"] as! Int,
                                                               monotonic: { clock.time })
            func discover() throws -> ControlDiscovery { try adapter.execute(.discover, gateway: gateway)
                .decoded(ControlDiscovery.self)
            }
            func snapshot() throws -> ControlSnapshot { try adapter.execute(
                .snapshot(instanceID: "independent-bcr"),
                gateway: gateway
            ).decoded(ControlSnapshot.self) }
            func page() throws -> ControlEventPage {
                try adapter.execute(
                    .events(instanceID: "independent-bcr", epoch: discover().expected.epoch, afterSequence: "0",
                            limit: 1024),
                    gateway: gateway
                ).decoded(ControlEventPage.self)
            }
            let profile = try discover().profile
            func value(_ symbolic: String?, _ row: ControlDescriptor, feedback: Bool = false) -> JSONValue {
                if ["on", "off", "blink"].contains(symbolic) { return .string(symbolic!) }
                if row.encoding == .boolean { return .bool(symbolic == "maximum") }
                let range = feedback ? row.feedback_range ?? row.range! : row.range!
                return .double(symbolic == "maximum" ? range.maximum : range.minimum)
            }
            executed[name] = 0
            for step in steps {
                clock.time = step["at_s"] as! Double
                let before = try snapshot(), beforePage = try page()
                let operation = step["operation"] as! String, expect = step["expect"] as! [String: Any]
                let descriptor = (step["role"] as? String).flatMap { roles[$0] }
                    .flatMap { id in profile.controls.first { $0.id == id } }
                var event: ControlEvent?, events: ControlEventPage?, failure: String?
                do {
                    switch operation {
                    case "snapshot": break
                    case "hardware_input":
                        let row = descriptor!
                        let entry = entries.first { BCRSurfaceControlAdapter.controlID($0.control) == row.id }!
                        let raw = value(step["value"] as? String, row)
                        device.onMessages?([MIDI1UMPCodec.feedback(
                            control: entry.midi,
                            value: raw.boolValue.map { $0 ? 127 : 0 } ?? UInt8(raw.finiteNumber!)
                        )])
                        event = try page().events.last
                        if step["disposition"] as? String ==
                            "ignored" { XCTAssertEqual(event?.reason, "engine_ignored") }
                    case "feedback", "feedback_failure":
                        let row = descriptor!
                        let raw = step["invalid_value"] as? String == "nan" ? JSONValue.double(.nan) : value(
                            step["value"] as? String,
                            row,
                            feedback: true
                        )
                        let update = ControlFeedback(
                            expected: try discover().expected,
                            expectedSequence: try discover().latest_sequence,
                            controlID: row.id,
                            kind: step["feedback_kind"] as! String,
                            value: raw
                        )
                        let beforeAccepted = device.accepted.count, beforeAttempts = device.attempts
                        device.failsSend = operation == "feedback_failure"
                        defer { device.failsSend = false }
                        do {
                            event = try adapter.execute(.feedback(update), gateway: gateway).decoded(ControlEvent.self)
                        } catch {
                            let code = BCRSurfaceControlAdapter.failureCode(error)
                            if operation == "feedback_failure" {
                                XCTAssertEqual(code, "delivery_failed")
                                XCTAssertEqual(device.attempts - beforeAttempts, 1)
                                XCTAssertEqual(device.accepted.count, beforeAccepted)
                                // Only the trusted test injection is normalized; production error is unchanged.
                                throw ControlContractError("test_transport_rejected")
                            }
                            throw error
                        }
                        if operation == "feedback" { XCTAssertEqual(device.accepted.count - beforeAccepted, 1) }
                    case "events": events = try page()
                    default: XCTFail("Unknown independent fixture operation: \(operation)")
                    }
                } catch { failure = BCRSurfaceControlAdapter.failureCode(error) }
                XCTAssertEqual(failure, expect["error"] as? String, name)
                let after = try snapshot()
                for (key, expected) in expect {
                    switch key {
                    case "error": break
                    case "atomic": XCTAssertEqual(before, after); XCTAssertEqual(beforePage, try page())
                    case "unknown_inputs": for role in expected as! [String] { XCTAssertNil(after.inputs[roles[role]!])
                        }
                    case "known_inputs": for (role, symbolic) in expected as! [String: String] {
                            let row = profile.controls.first { $0.id == roles[role]! }!
                            XCTAssertEqual(after.inputs[row.id], SurfaceControlSession.normalized(value(symbolic, row)))
                        }
                    case "sequence": XCTAssertEqual(after.latest_sequence, expected as? String)
                    case "disposition": XCTAssertEqual(event?.disposition.rawValue, expected as? String)
                    case "source": XCTAssertEqual(event?.source.rawValue, expected as? String)
                    case "origin": XCTAssertEqual(event?.origin.rawValue, expected as? String)
                    case "inputs_unchanged": XCTAssertEqual(before.inputs, after.inputs)
                    case "event_count": XCTAssertEqual(events?.events.count, expected as? Int)
                    default: XCTFail("Unchecked independent fixture expectation: \(key)")
                    }
                }
                executed[name]! += 1
            }
        }
        XCTAssertEqual(executed, ["ignored_button_edges_remain_unknown": 4, "value_feedback_failures_are_atomic": 8])
        XCTAssertEqual(skipped, ["accepted_button_edges_and_recovery": 12, "position_touch_independent_edges": 8])
        let report: [String: Any] = [
            "scope": "actual host adapter with test-only device; current visualization-only policy",
            "hardware_qualified": false,
            "executed": executed,
            "skipped": skipped,
            "skip_reason": "No accepted-button or physical touch role in current BCR map",
            "roles": roles
        ]
        let output = root.appendingPathComponent("build/e-next")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(
            to: output.appendingPathComponent("independent-fixture-report.json"),
            options: .atomic
        )
    }
}
