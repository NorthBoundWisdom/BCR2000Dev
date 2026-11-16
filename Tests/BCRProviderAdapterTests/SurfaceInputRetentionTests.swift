import BCRFoundation
import BCRMCPAdapter
import BCRProviderMCPAdapter
import BCRSurfaceDomain
import Foundation
import SurfaceControlContracts
import XCTest

@MainActor
final class SurfaceInputRetentionTests: XCTestCase {
    final class Clock { var time: Double = 10 }
    func host(_ clock: Clock, capacity: Int? = 4, eventCapacity: Int = 2,
              limits: ControlWriteLimits? = nil, aggregate: Int = 10000)
        throws -> (SurfaceSession, MCPApplicationGateway, BCRSurfaceControlAdapter)
    {
        let surface = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: surface,
                                            permissions: .init(
                                                writesPerSecond: aggregate,
                                                deviceControl: true,
                                                simulationControl: true
                                            ),
                                            now: { Date(timeIntervalSinceReferenceDate: 100) }, includeAgent: false)
        let adapter = try XCTUnwrap(SurfaceControlMCPModule.install(
            on: gateway, instanceID: "retention", permissions: .init(input: true, feedback: true, reset: true),
            eventCapacity: eventCapacity, inputEventCapacity: capacity, writeLimits: limits,
            monotonic: { clock.time }, holdScheduler: { _, _ in {} }
        ))
        return (surface, gateway, adapter)
    }

    func call(_ gateway: MCPApplicationGateway, _ name: String, _ fields: [String: JSONValue],
              error: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> JSONValue
    {
        let result = gateway.call("surface_control_" + name, arguments: .object(fields))
        XCTAssertEqual(result.isError, error != nil, "\(result.value)", file: file, line: line)
        if let error { XCTAssertEqual(result.value.value(for: "code"), .string(error), file: file, line: line) }
        return result.value
    }

    func page(
        _ gateway: MCPApplicationGateway,
        _ adapter: BCRSurfaceControlAdapter,
        after: String = "0",
        limit: Int = 128,
        error: String? = nil
    ) throws -> JSONValue {
        call(gateway, "input_events", ["expected": try .encoded(adapter.discovery().expected),
                                       "after_input_sequence": .string(after), "limit": .number(limit)], error: error)
    }

    func input(_ gateway: MCPApplicationGateway, _ adapter: BCRSurfaceControlAdapter,
               control: String = "pushEncoder.1.1", value: JSONValue = .number(20),
               hold: Double? = nil) throws -> JSONValue
    {
        let discovery = try adapter.discovery()
        var fields: [String: JSONValue] = ["expected": try .encoded(discovery.expected),
                                           "expected_input_sequence": .string(discovery.latest_input_sequence!),
                                           "control_id": .string(control),
                                           "encoding": .string(control.hasPrefix("button") ? "boolean" : "scalar"),
                                           "value": value]
        if let hold { fields["hold_s"] = .double(hold) }
        return call(gateway, "input", fields)
    }

    func feedback(_ gateway: MCPApplicationGateway, _ adapter: BCRSurfaceControlAdapter, error: String? = nil) throws {
        _ = call(gateway, "feedback", [
            "expected": try .encoded(adapter.discovery().expected),
            "control_id": .string("button.1.1"),
            "kind": .string("indicator"),
            "value": .string("on")
        ], error: error)
    }

    func testDefaultSevenDefinitionsStayEqualAndOnlyExplicitCapacityAddsOneRead() async throws {
        let (_, base, old) = try host(Clock(), capacity: nil)
        let (_, retained, current) = try host(Clock())
        let names = { (gateway: MCPApplicationGateway) in gateway.toolDefinitions.filter {
            $0.value(for: "name")?.stringValue?.hasPrefix("surface_control_") == true
        } }
        XCTAssertEqual(names(base).count, 7)
        XCTAssertEqual(names(retained).count, 8)
        XCTAssertEqual(
            names(retained).filter { $0.value(for: "name") != .string("surface_control_input_events") },
            names(base)
        )
        XCTAssertEqual(try old.discovery().contract_version, "1.3")
        XCTAssertEqual(try current.discovery().contract_version, "1.5")
        XCTAssertEqual(try current.discovery().profile.version, "1.5")
        XCTAssertTrue(try current.discovery().profile.capabilities.contains("events.input_retention"))
        XCTAssertEqual(names(retained).last?.value(for: "annotations")?.value(for: "readOnlyHint"), .bool(true))
    }

    func testFeedbackFloodPreservesAcceptedIgnoredExpiryAndPagedCASHighwater() async throws {
        let clock = Clock(); let (_, gateway, adapter) = try host(clock)
        XCTAssertEqual(try input(gateway, adapter).value(for: "disposition"), .string("accepted"))
        XCTAssertEqual(try input(gateway, adapter).value(for: "disposition"), .string("ignored"))
        _ = try input(gateway, adapter, control: "button.1.3", value: .bool(true), hold: 0.5)
        let beforeRenew = try adapter.discovery().latest_input_sequence
        _ = call(gateway, "renew", ["expected": try .encoded(adapter.discovery().expected),
                                    "control_id": .string("button.1.3"), "hold_s": .double(0.5)])
        XCTAssertEqual(try adapter.discovery().latest_input_sequence, beforeRenew)
        clock.time += 0.5
        for _ in 0 ..< 6 { try feedback(gateway, adapter) }
        let discovery = try adapter.discovery()
        _ = call(gateway, "events", ["instance_id": .string("retention"), "epoch": .string(discovery.expected.epoch),
                                     "after_sequence": .string("0"), "limit": .number(128)], error: "event_gap")
        let first = try page(gateway, adapter, limit: 2)
        let second = try page(gateway, adapter, after: "2", limit: 2)
        XCTAssertEqual(first.value(for: "latest_sequence"), .string(discovery.latest_sequence))
        XCTAssertEqual(second.value(for: "latest_sequence"), first.value(for: "latest_sequence"))
        XCTAssertEqual(first.value(for: "latest_input_sequence"), .string("4"))
        let events = first.value(for: "events")!.arrayValue! + second.value(for: "events")!.arrayValue!
        XCTAssertEqual(events.map { $0.value(for: "input_sequence") }, ["1", "2", "3", "4"].map(JSONValue.string))
        XCTAssertEqual(events[1].value(for: "disposition"), .string("ignored"))
        XCTAssertEqual(events[3].value(for: "reason"), .string("hold_expired"))
        XCTAssertTrue(events.allSatisfy { $0.value(for: "kind") == .string("input") })
        XCTAssertEqual(first.value(for: "input_event_capacity"), .number(4))
    }

    func testInputOverflowAndEverySimulationRebuildKeepCapacityAndClearOldHistory() async throws {
        let (surface, gateway, adapter) = try host(Clock(), capacity: 2)
        for value in 1 ... 3 { _ = try input(gateway, adapter, value: .number(value)) }
        _ = try page(gateway, adapter, error: "input_event_gap")
        let old = try adapter.discovery()
        _ = call(
            gateway,
            "reset",
            ["expected": try .encoded(old.expected), "expected_sequence": .string(old.latest_sequence)]
        )
        let resetPage = try page(gateway, adapter)
        XCTAssertEqual(resetPage.value(for: "input_event_capacity"), .number(2))
        XCTAssertEqual(resetPage.value(for: "events"), .array([]))
        _ = call(gateway, "input_events", ["expected": try .encoded(old.expected), "after_input_sequence": .string("0"),
                                           "limit": .number(128)], error: "stale_epoch")
        _ = try input(gateway, adapter)
        var definition = try XCTUnwrap(surface.engine.configuration.parameter("simulation.arm"))
        definition.name = "New metadata"
        try surface.updateParameter(definition)
        let changed = try page(gateway, adapter)
        XCTAssertEqual(changed.value(for: "input_event_capacity"), .number(2))
        XCTAssertEqual(changed.value(for: "events"), .array([]))
        XCTAssertEqual(try adapter.discovery().profile.version, "1.5")
        let previousMapping = try adapter.discovery().expected
        try surface.setAssignment(.init(control: .pushEncoder(group: 1, 1), target: .parameter("simulation.start")),
                                  for: .pushEncoder(group: 1, 1))
        let remapped = try page(gateway, adapter)
        XCTAssertEqual(remapped.value(for: "input_event_capacity"), .number(2))
        XCTAssertEqual(remapped.value(for: "events"), .array([]))
        _ = call(gateway, "input_events", ["expected": try .encoded(previousMapping),
                                           "after_input_sequence": .string("0"), "limit": .number(128)],
                 error: "stale_mapping")
    }

    func testReadAndParserDoNotSpendAggregateCategoryOrIndependentDisplayBudgets() async throws {
        let limits = ControlWriteLimits(inputPerWindow: 1, feedbackPerWindow: 1, renewPerWindow: 1, adminPerWindow: 1)
        for independent in [false, true] {
            let (_, gateway, adapter) = try host(Clock(), limits: independent ? limits : nil, aggregate: 1)
            for _ in 0 ..< 20 { _ = try page(gateway, adapter) }
            try feedback(gateway, adapter)
            for _ in 0 ..< 20 { _ = try page(gateway, adapter) }
            try feedback(gateway, adapter, error: "rate_limited")
        }
        let (_, gateway, adapter) = try host(Clock(), aggregate: 100)
        try gateway.withAuthenticatedSurfaceWriterID(adapter.principals.remoteWriterID, displayWriteLimit: 1) {
            for _ in 0 ..< 20 { _ = try page(gateway, adapter) }
            try feedback(gateway, adapter)
            try feedback(gateway, adapter, error: "rate_limited")
        }
        _ = call(gateway, "input_events", ["expected": try .encoded(adapter.discovery().expected),
                                           "after_input_sequence": .string("0"), "limit": .number(128),
                                           "writer_id": .string("forged")], error: "invalid_argument")
    }

    func testReadOnlyPermissionStillAllowsRetainedReadWithoutAnyWriteGrant() async throws {
        let (_, gateway, adapter) = try host(Clock())
        gateway.permissions.parameterWrite = false
        let result = try page(gateway, adapter)
        XCTAssertEqual(result.value(for: "events"), .array([]))
        XCTAssertEqual(result.value(for: "input_event_capacity"), .number(4))
        _ = call(gateway, "input", ["expected": try .encoded(adapter.discovery().expected),
                                    "expected_input_sequence": .string("0"), "control_id": .string("pushEncoder.1.1"),
                                    "encoding": .string("scalar"), "value": .number(1)], error: "permission_denied")
    }

    func testHardwareRetentionKeepsRemoteDenialsDoubleDisplayGateAndUnknownOnReconnection() async throws {
        for policy in [HardwareOutputPolicy.observe, .write] {
            let device = ProviderHardwareVisibilityTests.Device()
            let control = BCRControlID.pushEncoder(group: 1, 1)
            let map = HardwareMap(entries: [.init(
                control: control,
                midi: .init(kind: .controlChange, channel: 0, number: 8)
            )])
            let surface = SurfaceSession(hardwareDevice: device, hardwareMap: map,
                                         configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                         hardwareOutput: policy, hardwareLifecycleFeedback: false,
                                         saveHardwareMap: { _ in }, saveConfiguration: { _ in })
            surface.selectSource(.hardware)
            let gateway = MCPApplicationGateway(session: surface, includeAgent: false)
            try SurfaceControlMCPModule.installHardware(on: gateway, instanceID: "hw-retention",
                                                        permissions: .init(feedback: true), inputEventCapacity: 2,
                                                        monotonic: { 10 })
            let discovery = call(gateway, "discover", [:])
            XCTAssertEqual(discovery.value(for: "contract_version"), .string("1.5"))
            let expected = discovery.value(for: "expected")!
            device.onMessages?([.controlChange(channel: 0, number: 8, value: 45)])
            let inputFeedbackCount = device.sent.count
            let first = call(
                gateway,
                "input_events",
                ["expected": expected, "after_input_sequence": .string("0"), "limit": .number(128)]
            )
            XCTAssertEqual(first.value(for: "events")?.arrayValue?.count, 1)
            XCTAssertEqual(first.value(for: "input_event_capacity"), .number(2))
            _ = call(gateway, "input", ["expected": expected, "expected_input_sequence": .string("1"),
                                        "control_id": .string("pushEncoder.1.1"), "encoding": .string("scalar"),
                                        "value": .number(1)], error: "permission_denied")
            _ = call(gateway, "renew", ["expected": expected, "control_id": .string("pushEncoder.1.1"),
                                        "hold_s": .number(1)], error: "unsupported_hold")
            _ = call(
                gateway,
                "reset",
                ["expected": expected, "expected_sequence": first.value(for: "latest_sequence")!],
                error: "unsupported_tool"
            )
            _ = call(gateway, "feedback", ["expected": expected, "control_id": .string("pushEncoder.1.1"),
                                           "kind": .string("value"), "value": .number(64)],
                     error: policy == .observe ? "permission_denied" : nil)
            XCTAssertEqual(device.sent.count, inputFeedbackCount + (policy == .observe ? 0 : 1))
            device.connection = MIDIConnectionSnapshot(); device.onConnection?(device.connection)
            let next = call(gateway, "discover", [:]).value(for: "expected")!
            XCTAssertNotEqual(next, expected)
            let empty = call(
                gateway,
                "input_events",
                ["expected": next, "after_input_sequence": .string("0"), "limit": .number(128)]
            )
            XCTAssertEqual(empty.value(for: "events"), .array([]))
            XCTAssertEqual(empty.value(for: "input_event_capacity"), .number(2))
            XCTAssertEqual(
                call(gateway, "snapshot", ["instance_id": .string("hw-retention")]).value(for: "inputs"),
                .object([:])
            )
            XCTAssertEqual(device.sent.count, inputFeedbackCount + (policy == .observe ? 0 : 1))
        }
    }
}
