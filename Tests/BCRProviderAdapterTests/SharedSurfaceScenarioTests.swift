import Foundation
import XCTest
import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import BCRProviderMCPAdapter
import SurfaceControlContracts
import SurfacePluginContracts

private enum ScenarioFailure: Error { case assertion(String) }
private func requireScenario(_ value: Bool, _ message: String) throws {
    guard value else { throw ScenarioFailure.assertion(message) }
}

private func commandOutput(_ args: [String], root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    process.currentDirectoryURL = root
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    try requireScenario(process.terminationStatus == 0, "metadata command failed")
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private let scenarioRoles = [
    "input_a": "simulation.arm",
    "input_b": "simulation.start",
    "input_c": "simulation.pause",
    "input_d": "simulation.cancel",
    "feedback_state": "simulation.state",
    "feedback_progress": "simulation.progress",
    "feedback_link": "simulation.link",
    "hold_input": "simulation.hold"
]

@MainActor
private final class BCRFixtureHost {
    final class Clock { var time: Double = 0 }
    let clock = Clock()
    let session: SurfaceSession
    let gateway: MCPApplicationGateway
    let adapter: BCRSurfaceControlAdapter
    let capacity: Int
    var controls: BCRFixtureHost { self }
    var expected: ControlExpected { get throws { try adapter.discovery().expected } }
    var profile: ControlProfile { get throws { try adapter.discovery().profile } }
    init(instanceID: String, epoch: String, eventCapacity: Int) throws {
        capacity = eventCapacity
        session = SurfaceSession(
            hardwareDevice: MockSurfaceDevice(),
            configuration: SurfaceControlMCPModule.simulationConfiguration(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        gateway = MCPApplicationGateway(
            session: session,
            permissions: .init(deviceControl: true, simulationControl: true),
            includeAgent: false
        )
        let clock = self.clock
        // The runner is the scheduler: `advance` processes due leases exactly as the host timer would.
        adapter = try BCRSurfaceControlAdapter(surface: session, instanceID: instanceID,
                                               permissions: .init(input: true, feedback: true, reset: true),
                                               eventCapacity: eventCapacity, monotonic: { clock.time },
                                               holdScheduler: { _, _ in {} }, automaticHoldExpiry: false)
    }

    func renew(_ request: ControlRenew, at time: Double) throws -> ControlRenewResult {
        clock.time = time
        return try adapter.execute(.renew(request), gateway: gateway).decoded(ControlRenewResult.self)
    }

    func advance(to time: Double) throws -> [ControlEvent] {
        clock.time = time
        return try adapter.processHoldExpiries()
    }

    func discovery() throws -> ControlDiscovery { try adapter.discovery() }
    func snapshot(at time: Double) throws -> ControlSnapshot {
        clock.time = time
        return try adapter.execute(.snapshot(instanceID: expected.instance_id), gateway: gateway)
            .decoded(ControlSnapshot.self)
    }

    func events(instanceID: String, epoch: String, afterSequence: String, limit: Int,
                at time: Double) throws -> ControlEventPage
    {
        clock.time = time
        return try adapter.execute(
            .events(instanceID: instanceID, epoch: epoch, afterSequence: afterSequence, limit: limit),
            gateway: gateway
        ).decoded(ControlEventPage.self)
    }

    func input(_ input: ControlInput, at time: Double) throws -> ControlEvent {
        clock.time = time
        return try adapter.execute(.input(input), gateway: gateway).decoded(ControlEvent.self)
    }

    func feedback(_ feedback: ControlFeedback, at time: Double) throws -> ControlEvent {
        clock.time = time
        return try adapter.execute(.feedback(feedback), gateway: gateway).decoded(ControlEvent.self)
    }

    func reset(epoch: String, at time: Double) throws {
        clock.time = time
        let current = try discovery()
        _ = try adapter.execute(
            .reset(expected: current.expected, expectedSequence: current.latest_sequence),
            gateway: gateway
        )
    }
}

@MainActor
private func scenarioFingerprint(_ host: BCRFixtureHost, at requested: Double) throws -> JSONValue {
    // An unprocessed due lease makes every public read fail; observe just before it, which is still
    // after the last write (a lease deadline is always later than the write that created it).
    var time = requested
    if let deadline = host.adapter.nextHoldDeadline, deadline <= requested { time = deadline.nextDown }
    let snapshot = try host.snapshot(at: time)
    let cursor = UInt64(snapshot.latest_sequence)!
    let first = cursor > UInt64(host.capacity) ? cursor - UInt64(host.capacity) : 0
    let page = try host.events(
        instanceID: host.expected.instance_id,
        epoch: host.expected.epoch,
        afterSequence: String(first),
        limit: 1024,
        at: time
    )
    let parameters = Dictionary(uniqueKeysWithValues: host.session.engine.parameterValues.map { (
        $0.key.rawValue,
        JSONValue.double($0.value)
    ) })
    let states = Dictionary(uniqueKeysWithValues: BCRLayout.allControls.map { control in
        let state = host.session.engine.state(of: control)
        return (BCRSurfaceControlAdapter.controlID(control), JSONValue.object(["raw": .number(Int(state.rawValue)),
                                                                               "count": .number(state.eventCount),
                                                                               "input": state.lastInput
                                                                                   .map { .number(Int($0)) } ?? .null]))
    })
    return .object(["expected": try .encoded(host.expected), "sequence": .string(snapshot.latest_sequence),
                    "inputs": .object(snapshot.inputs), "feedback": try .encoded(snapshot.feedback),
                    "input_sequence": snapshot.latest_input_sequence.map(JSONValue.string) ?? .null,
                    "holds": try .encoded(snapshot.holds ?? [:]),
                    "journal": try .encoded(page.events),
                    "parameters": .object(parameters), "controls": .object(states),
                    "mock_inputs": try .encoded(host.session.mock.inputDataValues),
                    "mock_display": try .encoded(host.session.mock.values)])
}

@MainActor
final class SharedSurfaceScenarioTests: XCTestCase {
    func testSharedVersionedFixtureDrivesRealBCRMockAndSession() throws {
        try run(fixture: "surface-control-software-v1", steps: 40)
    }

    func testSharedContract11FixtureDrivesHoldRenewAndAdvance() throws {
        try run(fixture: "surface-control-software-v1.1", steps: 65)
    }

    func testSharedContract12FixtureDrivesUnsequencedFeedbackHoldsAndDeclarations() throws {
        try run(fixture: "surface-control-software-v1.2", steps: 83)
    }

    func testSharedContract13FixtureDrivesIndependentCASAndTrustedWriters() throws {
        try run(fixture: "surface-control-software-v1.3", steps: 97)
    }

    private func run(fixture name: String, steps expectedSteps: Int) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent("build/seed/SurfacePlugins/fixtures/\(name).json")
        let document = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture))
        let scenarios = try XCTUnwrap(document.value(for: "scenarios")?.arrayValue)
        var results: [JSONValue] = []
        var roles: [String: String] = [:]
        for scenario in scenarios {
            let name = try XCTUnwrap(scenario.value(for: "id")?.stringValue)
            let capacity = try XCTUnwrap(scenario.value(for: "event_capacity")?.exactIntValue)
            let names = scenario.value(for: "instances")?.arrayValue?.compactMap(\.stringValue) ?? ["a"]
            var hosts = try Dictionary(uniqueKeysWithValues: names.map { (
                $0,
                try BCRFixtureHost(instanceID: "fixture.\($0)", epoch: "\(name).\($0).initial", eventCapacity: capacity)
            ) })
            var initial = try hosts.mapValues { try $0.expected }
            var lastInput: [String: ControlInput] = [:]
            var sequences = Dictionary(uniqueKeysWithValues: names.map { ($0, "0") })
            var accepted = Dictionary(uniqueKeysWithValues: names.map { ($0, 0) })
            let steps = try XCTUnwrap(scenario.value(for: "steps")?.arrayValue)
            for (index, step) in steps.enumerated() {
                let selected = step.value(for: "instance")?.stringValue ?? "a"
                var host = hosts[selected]!
                let scheduled = try XCTUnwrap(step.value(for: "at_s")?.finiteNumber)
                let time = step.value(for: "clock_override_s")?.finiteNumber ?? scheduled
                let operation = try XCTUnwrap(step.value(for: "operation")?.stringValue)
                let expected = try XCTUnwrap(step.value(for: "expect")?.objectValue)
                let before = try scenarioFingerprint(host, at: scheduled)
                let beforeInputs = before.value(for: "inputs")?.objectValue ?? [:]
                let beforeEpoch = (try host.expected).epoch
                let beforeInstance = (try host.expected).instance_id
                let countBefore = accepted[selected]!
                var actualError: String?
                var event: ControlEvent?
                var page: ControlEventPage?
                var renewal: ControlRenewResult?
                var expired: [ControlEvent] = []
                func mapped(_ role: String) throws -> ControlDescriptor {
                    let control = try XCTUnwrap((try host.profile).controls
                        .first {
                            role == "blocked_input" ? $0.accepts_input == false : $0.mapping?.id == scenarioRoles[role]
                        })
                    roles[role] = control.id
                    return control
                }
                func role(of controlID: String) -> String? {
                    scenarioRoles.first { pair in (try? host.profile)?.controls
                        .first { $0.id == controlID }?.mapping?.id == pair.value
                    }?.key
                }
                do {
                    switch operation {
                    case "snapshot", "refresh_sequence", "refresh_input_sequence": _ = try host.snapshot(at: time)
                    case "input", "feedback":
                        let role = try XCTUnwrap(step.value(for: "role")?.stringValue)
                        let control = try mapped(role)
                        let suppliedExpected = step
                            .value(for: "expected_scope") == .string("initial") ? initial[selected]! :
                            (try host.expected)
                        let range = operation == "feedback" ? (control.feedback_range ?? control.range) : control.range
                        let value: JSONValue
                        if step.value(for: "invalid_value") == .string("nan") { value = .double(.nan) }
                        else if step.value(for: "value") == .string("maximum") { value = .number(Int(range!.maximum)) }
                        else if step
                            .value(for: "value") ==
                            .string("minimum")
                        {
                            value = control.encoding == .boolean ? .bool(false) : .number(Int(range!.minimum))
                        } else if step.value(for: "value") == .string("rest") { value = control.hold!.rest_value }
                        else if step.value(for: "value") == .string("active") {
                            let rest = control.hold!.rest_value
                            value = control.encoding == .boolean ? .bool(rest.boolValue != true) :
                                .number(Int(rest.finiteNumber == range!.maximum ? range!.minimum : range!.maximum))
                        } else { value = step.value(for: "value")! }
                        if operation == "input" {
                            let request = ControlInput(
                                expected: suppliedExpected,
                                expectedSequence: step.value(for: "expected_input_sequence") == nil ?
                                    (step.value(for: "expected_sequence")?.stringValue ?? sequences[selected]!) : nil,
                                expectedInputSequence: step.value(for: "expected_input_sequence")?.stringValue,
                                controlID: control.id,
                                encoding: step.value(for: "encoding")?.stringValue ?? control.encoding.rawValue,
                                value: value,
                                holdSeconds: step.value(for: "hold_s")?.finiteNumber
                            )
                            lastInput[selected] = request
                            event = try host.input(request, at: time)
                        } else {
                            let kind = document.value(for: "roles")!.value(for: role)!.value(for: "feedback_kind")!
                                .stringValue!
                            event = try host.feedback(
                                .init(
                                    expected: suppliedExpected,
                                    expectedSequence: step.value(for: "omit_sequence") == .bool(true) ? nil :
                                        (step.value(for: "expected_sequence")?.stringValue ?? sequences[selected]!),
                                    controlID: control.id,
                                    kind: kind,
                                    value: value
                                ),
                                at: time
                            )
                        }
                    case "replay_last_write": event = try host.input(lastInput[selected]!, at: time)
                    case "renew":
                        let control = try mapped(try XCTUnwrap(step.value(for: "role")?.stringValue))
                        renewal = try host.renew(.init(expected: try host.expected, controlID: control.id,
                                                       holdSeconds: try XCTUnwrap(step.value(for: "hold_s")?
                                                           .finiteNumber)),
                                                 at: time)
                    case "advance": expired = try host.advance(to: time)
                    case "reset":
                        try host.reset(epoch: "\(name).\(selected).reset.\(index)", at: time)
                        accepted[selected] = 0
                    case "restart":
                        host = try BCRFixtureHost(
                            instanceID: "fixture.\(selected).replacement",
                            epoch: "\(name).\(selected).restart.\(index)",
                            eventCapacity: capacity
                        )
                        accepted[selected] = 0
                    case "events":
                        page = try host.controls.events(
                            instanceID: (try host.expected).instance_id,
                            epoch: (try host.expected).epoch,
                            afterSequence: step.value(for: "after_sequence")!.stringValue!,
                            limit: 1024,
                            at: time
                        )
                    default: throw ScenarioFailure.assertion("unsupported operation")
                    }
                } catch let error as ControlContractError { actualError = error.code }
                if event?.kind == .input, event?.disposition == .accepted { accepted[selected]! += 1 }
                accepted[selected]! += expired.filter { $0.kind == .input && $0.disposition == .accepted }.count
                let after = try scenarioFingerprint(host, at: scheduled)
                let snapshot = try host.controls.snapshot(at: min(scheduled, host.adapter.nextHoldDeadline
                        .map { $0 <= scheduled ? $0.nextDown : scheduled } ?? scheduled))
                if actualError == nil, !(operation == "feedback" && step.value(for: "omit_sequence") == .bool(true)) {
                    sequences[selected] = snapshot.latest_sequence
                }
                func writerKind(_ id: String?) -> String? {
                    guard let id else { return nil }
                    if id == host.adapter.principals.remoteWriterID { return "remote" }
                    if id == host.adapter.principals.interfaceWriterID { return "interface" }
                    if id == host.adapter.principals.systemWriterID { return "system" }
                    return nil
                }
                let writer = writerKind(event?.writer_id ?? expired.last?.writer_id)
                var checks: [Bool] = [actualError == expected["error"]?.stringValue]
                if let inputSequence = expected["latest_input_sequence"]?.stringValue {
                    checks.append((page?.latest_input_sequence ?? snapshot.latest_input_sequence) == inputSequence)
                }
                if let kind = expected["writer_kind"]?.stringValue { checks.append(writer == kind) }
                if let sequences = expected["event_input_sequences"]?.arrayValue {
                    checks.append(page?.events.map { $0.input_sequence.map(JSONValue.string) ?? .null } == sequences)
                }
                if let kinds = expected["event_writer_kinds"]?.arrayValue {
                    checks.append(page?.events.map { writerKind($0.writer_id).map(JSONValue.string) ?? .null } == kinds)
                }
                if let disposition = expected["disposition"]?
                    .stringValue { checks.append(event?.disposition.rawValue == disposition) }
                if expected["atomic"] == .bool(true) { checks.append(before == after) }
                if expected["inputs_unchanged"] == .bool(true) { checks.append(beforeInputs == snapshot.inputs) }
                if expected["epoch_changed"] == .bool(true) { checks.append(beforeEpoch != (try host.expected).epoch) }
                if expected["instance_changed"] ==
                    .bool(true) { checks.append(beforeInstance != (try host.expected).instance_id) }
                if let sequence = expected["sequence"]?
                    .stringValue { checks.append(snapshot.latest_sequence == sequence) }
                if let count = expected["accepted_input_count"]?
                    .exactIntValue { checks.append(accepted[selected] == count) }
                if let delta = expected["accepted_input_delta"]?
                    .exactIntValue { checks.append(accepted[selected]! - countBefore == delta) }
                if let count = expected["event_count"]?.exactIntValue { checks.append(page?.events.count == count) }
                if let latest = expected["latest_sequence"]?
                    .stringValue { checks.append((page?.latest_sequence ?? snapshot.latest_sequence) == latest) }
                if let at = expected["hold_deadline_at_s"]?.finiteNumber {
                    let deadline = renewal?.hold_deadline ?? event?.hold_deadline
                    checks.append(deadline.map { abs($0 - at) < 1e-9 } == true)
                }
                if let held = expected["holds"]?.arrayValue?.compactMap(\.stringValue) {
                    let holds = operation == "events" ? (page?.holds ?? [:]) : (snapshot.holds ?? [:])
                    checks.append(Set(holds.keys.compactMap(role(of:))) == Set(held) && holds.count == held.count)
                }
                if let deadlines = expected["hold_deadlines_at_s"]?.objectValue {
                    let holds = page?.holds ?? [:]
                    checks.append(holds.count == deadlines.count)
                    for (role, deadline) in deadlines {
                        let control = try mapped(role)
                        checks.append(holds[control.id].map { abs($0 - deadline.finiteNumber!) < 1e-9 } == true)
                    }
                }
                if let list = expected["expired"]?.arrayValue?.compactMap(\.stringValue) {
                    checks.append(expired.map { role(of: $0.control_id) ?? $0.control_id } == list
                        && expired.allSatisfy { $0.reason == "hold_expired" && $0.origin == .remote })
                }
                if let reasons = expected["event_reasons"]?.arrayValue {
                    checks.append(page?.events.map { $0.reason.map(JSONValue.string) ?? .null } == reasons)
                }
                if let known = expected["known_inputs"]?.objectValue {
                    for (role, endpoint) in known {
                        let control = (try host.profile).controls.first { $0.mapping?.id == scenarioRoles[role] }!
                        switch endpoint {
                        case .string("rest"): checks.append(snapshot.inputs[control.id] == control.hold?.rest_value)
                        case .string("active"):
                            checks.append(snapshot.inputs[control.id] != nil
                                && snapshot.inputs[control.id] != control.hold?.rest_value)
                        default:
                            let value = endpoint == .string("minimum") ? control.range!.minimum : control.range!.maximum
                            checks.append(snapshot.inputs[control.id]?.finiteNumber == value)
                        }
                    }
                }
                let passed = checks.allSatisfy { $0 }
                results.append(.object([
                    "scenario": .string(name),
                    "step": .number(index),
                    "operation": .string(operation),
                    "status": .string(passed ? "pass" : "fail"),
                    "actual_error": actualError.map(JSONValue.string) ?? .null,
                    "disposition": event.map { .string($0.disposition.rawValue) } ?? .null,
                    "accepted_input_count": .number(accepted[selected]!),
                    "sequence": .string(snapshot.latest_sequence),
                    "input_sequence": snapshot.latest_input_sequence.map(JSONValue.string) ?? .null,
                    "writer_kind": writer.map(JSONValue.string) ?? .null,
                    "epoch_changed": .bool(beforeEpoch != (try host.expected).epoch)
                ]))
                hosts[selected] = host
                XCTAssertTrue(passed, "scenario \(name) step \(index) failed: \(actualError ?? "no error")")
            }
            // Retain initial identity for stale-request checks; it is never auto-refreshed.
            initial.removeAll()
        }
        let hash = try commandOutput(
            ["python3", "-c", "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())",
             fixture.path],
            root: root
        )
        let sharedLock = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(contentsOf: root.appendingPathComponent("configs/surface_plugins.lock.json"))
        )
        let report: JSONValue = .object([
            "fixture": document.value(for: "scenario_id")!,
            "fixture_sha256": .string(hash),
            "source": .string("simulation"),
            "host_revision": .string(try commandOutput(["git", "rev-parse", "HEAD"], root: root)),
            "host_dirty": .bool(!(try commandOutput(["git", "status", "--porcelain"], root: root)).isEmpty),
            "shared_revision": sharedLock.value(for: "revision")!,
            "profile_id": .string("bcr2000.mock"),
            "profile_version": .string("1.3"),
            "contract_version": .string(ControlDiscovery.contractVersion),
            "roles": try .encoded(roles),
            "scope": .string("inprocess_real_mock_session"),
            "steps": .array(results),
            "pass": .bool(results.allSatisfy { $0.value(for: "status") == .string("pass") })
        ])
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("build/\(name)-report.json"))
        XCTAssertEqual(results.count, expectedSteps)
    }
}
