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
    "feedback_link": "simulation.link"
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
        adapter = try BCRSurfaceControlAdapter(surface: session, instanceID: instanceID,
                                               permissions: .init(input: true, feedback: true, reset: true),
                                               eventCapacity: eventCapacity, monotonic: { clock.time })
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
private func scenarioFingerprint(_ host: BCRFixtureHost, at time: Double) throws -> JSONValue {
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
                    "journal": try .encoded(page.events),
                    "parameters": .object(parameters), "controls": .object(states),
                    "mock_inputs": try .encoded(host.session.mock.inputDataValues),
                    "mock_display": try .encoded(host.session.mock.values)])
}

@MainActor
final class SharedSurfaceScenarioTests: XCTestCase {
    func testSharedVersionedFixtureDrivesRealBCRMockAndSession() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent("build/seed/SurfacePlugins/fixtures/surface-control-software-v1.json")
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
                let beforeInputs = try host.controls.snapshot(at: scheduled).inputs
                let beforeEpoch = (try host.expected).epoch
                let beforeInstance = (try host.expected).instance_id
                let countBefore = accepted[selected]!
                var actualError: String?
                var event: ControlEvent?
                var page: ControlEventPage?
                do {
                    switch operation {
                    case "snapshot": break
                    case "input", "feedback":
                        let role = try XCTUnwrap(step.value(for: "role")?.stringValue)
                        let mappedID = scenarioRoles[role]!
                        let control = try XCTUnwrap((try host.profile).controls.first { $0.mapping?.id == mappedID })
                        roles[role] = control.id
                        let suppliedExpected = step
                            .value(for: "expected_scope") == .string("initial") ? initial[selected]! :
                            (try host.expected)
                        let range = operation == "feedback" ? (control.feedback_range ?? control.range) : control.range
                        let value: JSONValue
                        if step.value(for: "invalid_value") == .string("nan") { value = .double(.nan) }
                        else if step.value(for: "value") == .string("maximum") { value = .number(Int(range!.maximum)) }
                        else if step.value(for: "value") == .string("minimum") { value = .number(Int(range!.minimum)) }
                        else { value = step.value(for: "value")! }
                        if operation == "input" {
                            let request = ControlInput(
                                expected: suppliedExpected,
                                expectedSequence: (try host.discovery()).latest_sequence,
                                controlID: control.id,
                                encoding: step.value(for: "encoding")?.stringValue ?? control.encoding.rawValue,
                                value: value
                            )
                            lastInput[selected] = request
                            event = try host.input(request, at: time)
                        } else {
                            let kind = document.value(for: "roles")!.value(for: role)!.value(for: "feedback_kind")!
                                .stringValue!
                            event = try host.feedback(
                                .init(
                                    expected: suppliedExpected,
                                    expectedSequence: (try host.discovery()).latest_sequence,
                                    controlID: control.id,
                                    kind: kind,
                                    value: value
                                ),
                                at: time
                            )
                        }
                    case "replay_last_write": event = try host.input(lastInput[selected]!, at: time)
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
                let snapshot = try host.controls.snapshot(at: scheduled)
                let after = try scenarioFingerprint(host, at: scheduled)
                var checks: [Bool] = [actualError == expected["error"]?.stringValue]
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
                    .stringValue { checks.append(page?.latest_sequence == latest) }
                if let known = expected["known_inputs"]?.objectValue {
                    for (role, endpoint) in known {
                        let control = (try host.profile).controls.first { $0.mapping?.id == scenarioRoles[role] }!
                        let value = endpoint == .string("minimum") ? control.range!.minimum : control.range!.maximum
                        checks.append(snapshot.inputs[control.id]?.finiteNumber == value)
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
            "profile_version": .string("1.0"),
            "roles": try .encoded(roles),
            "scope": .string("inprocess_real_mock_session"),
            "steps": .array(results),
            "pass": .bool(results.allSatisfy { $0.value(for: "status") == .string("pass") })
        ])
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("build/surface-scenario-report.json"))
        XCTAssertEqual(results.count, 40)
    }
}
