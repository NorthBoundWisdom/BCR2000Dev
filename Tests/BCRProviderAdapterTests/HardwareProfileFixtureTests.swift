import Foundation
import XCTest
import BCRFoundation
import BCRSurfaceDomain
import BCRProviderMCPAdapter
import SurfacePluginContracts
import SurfaceControlContracts

@MainActor
final class HardwareProfileFixtureTests: XCTestCase {
    func testSharedHardwareFixtureAgainstHostProfileWithExplicitMissingRoleCoverage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let document = try JSONSerialization
            .jsonObject(with: Data(contentsOf: root
                    .appendingPathComponent(
                        "build/seed/SurfacePlugins/fixtures/surface-control-hardware-v1.4.json"
                    ))) as! [String: Any]
        let (surface, _, _) = try HardwareSurfaceControlTests.makeFixture(.write, feedback: true)
        let profile = try BCRHardwareSurfaceControlAdapter.profile(surface)
        let roles = [
            "input_a": "pushEncoder.1.1",
            "button_input": "button.1.1",
            "feedback_state": "button.1.1",
            "feedback_progress": "pushEncoder.2.1"
        ]
        var count = 0
        var unavailableSteps = 0
        for scene in document["scenarios"] as! [[String: Any]] {
            if ["unknown_and_observations", "link_generations"].contains(scene["id"] as? String ?? "") {
                // These scenarios depends on relative/touch roles absent from this device profile.
                // Preserve all shared assertions; report unsupported dependent coverage explicitly.
                unavailableSteps += (scene["steps"] as! [[String: Any]]).count
                continue
            }
            var session = try SurfaceControlSession(
                instanceID: "fixture",
                epoch: "initial",
                profile: profile,
                eventCapacity: scene["event_capacity"] as! Int
            )
            try session.transitionHardware(epoch: "connected", linkState: .connected, at: 0)
            let initial = session.expected
            for (index, step) in (scene["steps"] as! [[String: Any]]).enumerated() {
                count += 1
                let time = step["at_s"] as! Double, operation = step["operation"] as! String,
                    expect = step["expect"] as! [String: Any]
                let before = try session.snapshot(at: time)
                let control = (step["role"] as? String).flatMap { roles[$0] }
                    .flatMap { id in profile.controls.first { $0.id == id } }
                let symbolic = step["value"] as? String
                let value: JSONValue = control.map { row in
                    if row.encoding == .boolean { return .bool(symbolic == "maximum") }
                    let range = row.feedback_range ?? row.range!
                    return .double(symbolic == "maximum" ? range.maximum : range.minimum)
                } ?? .null
                var event: ControlEvent?, page: ControlEventPage?, error: String?
                do {
                    switch operation {
                    case "snapshot": break
                    case "hardware_input":
                        let row = control!
                        let input = ControlHardwareInput(
                            expected: session.expected,
                            controlID: row.id,
                            encoding: row.encoding.rawValue,
                            value: value
                        )
                        try session.validateHardwareInput(input, at: time, writerID: "fixture.hardware")
                        event = try session.recordHardwareInput(
                            input,
                            disposition: ControlDisposition(rawValue: step["disposition"] as? String ?? "accepted")!,
                            reason: step["reason"] as? String,
                            at: time,
                            writerID: "fixture.hardware"
                        )
                    case "hardware_link": try session.transitionHardware(
                            epoch: "transition-\(index)",
                            linkState: ControlLink.State(rawValue: step["link_state"] as! String)!,
                            at: time
                        )
                    case "feedback":
                        let row = control!, kind = row.feedback_kinds[0]
                        event = try session.recordFeedback(
                            .init(expected: session.expected, expectedSequence: session.discovery().latest_sequence,
                                  controlID: row.id, kind: kind.rawValue,
                                  value: kind == .indicator ? .string(symbolic!) : value),
                            origin: .remote,
                            at: time,
                            writerID: "fixture.remote"
                        )
                    case "input":
                        let row = control!
                        try session.validateInput(
                            .init(expected: session.expected, expectedSequence: session.discovery().latest_sequence,
                                  controlID: row.id, encoding: row.encoding.rawValue, value: value),
                            at: time
                        )
                    case "renew": try session.validateRenew(
                            .init(expected: session.expected, controlID: control!.id,
                                  holdSeconds: step["hold_s"] as! Double),
                            at: time
                        )
                    case "reset": try session.reset(
                            expected: session.expected,
                            expectedSequence: session.discovery().latest_sequence,
                            epoch: "forbidden",
                            at: time
                        )
                    case "events": page = try session.events(
                            instanceID: "fixture",
                            epoch: step["expected_scope"] as? String == "initial" ? initial.epoch : session.expected
                                .epoch,
                            afterSequence: step["after_sequence"] as? String ?? "0",
                            at: time
                        )
                    default: XCTFail("unsupported fixture operation \(operation)")
                    }
                } catch let failure as ControlContractError { error = failure.code }
                XCTAssertEqual(error, expect["error"] as? String, "\(scene["id"]!) step \(index)")
                let after = try session.snapshot(at: time)
                for (key, expected) in expect {
                    switch key {
                    case "error": break
                    case "atomic": XCTAssertEqual(before, after)
                    case "unknown_inputs": for role in expected as! [String] { XCTAssertNil(after.inputs[roles[role]!])
                        }
                    case "sequence": XCTAssertEqual(session.discovery().latest_sequence, expected as? String)
                    case "link_state": XCTAssertEqual(after.link?.state.rawValue, expected as? String)
                    case "disposition": XCTAssertEqual(event?.disposition.rawValue, expected as? String)
                    case "source": XCTAssertEqual(event?.source.rawValue, expected as? String)
                    case "origin": XCTAssertEqual(event?.origin.rawValue, expected as? String)
                    case "inputs_unchanged": XCTAssertEqual(before.inputs, after.inputs)
                    case "epoch_changed": XCTAssertNotEqual(
                            before.discovery.expected.epoch,
                            after.discovery.expected.epoch
                        )
                    case "event_count": XCTAssertEqual(page?.events.count, expected as? Int)
                    default: XCTFail("unchecked fixture expectation \(key)")
                    }
                }
            }
        }
        XCTAssertEqual(count, 15)
        XCTAssertEqual(unavailableSteps, 17)
    }
}
