import BCRFoundation
import BCRMCPAdapter
import BCRProviderMCPAdapter
import BCRSurfaceDomain
import Foundation
import SurfaceControlContracts
import XCTest

@MainActor
final class SurfaceControl13Tests: XCTestCase {
    final class Clock { var time: Double = 10 }
    func host(_ clock: Clock, limits: BCRSurfaceControlAdapter.WriteLimits? = nil, aggregate: Int = 1000)
        throws -> (MCPApplicationGateway, BCRSurfaceControlAdapter)
    {
        let surface = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: surface,
                                            permissions: .init(writesPerSecond: aggregate, deviceControl: true,
                                                               simulationControl: true), includeAgent: false)
        let adapter = try XCTUnwrap(SurfaceControlMCPModule.install(
            on: gateway, instanceID: "contract-13", permissions: .init(input: true, feedback: true, reset: true),
            writeLimits: limits, monotonic: { clock.time }, holdScheduler: { _, _ in {} }
        ))
        return (gateway, adapter)
    }

    func input(_ adapter: BCRSurfaceControlAdapter, control: String = "pushEncoder.1.1",
               value: JSONValue = .number(127), sequence: String? = nil,
               hold: Double? = nil) throws -> [String: JSONValue]
    {
        let discovery = try adapter.discovery()
        var fields: [String: JSONValue] = [
            "expected": try .encoded(discovery.expected),
            "expected_input_sequence": .string(sequence ?? discovery.latest_input_sequence!),
            "control_id": .string(control), "encoding": .string(control.hasPrefix("button") ? "boolean" : "scalar"),
            "value": value
        ]
        if let hold { fields["hold_s"] = .double(hold) }
        return fields
    }

    func call(_ gateway: MCPApplicationGateway, _ suffix: String, _ fields: [String: JSONValue],
              error: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> JSONValue
    {
        let result = gateway.call("surface_control_" + suffix, arguments: .object(fields))
        XCTAssertEqual(result.isError, error != nil, "\(result.value)", file: file, line: line)
        if let error { XCTAssertEqual(result.value.objectValue?["code"], .string(error), file: file, line: line) }
        return result.value
    }

    func testIndependentInputCASAndTrustedRemoteInterfaceExpiryWriters() throws {
        let clock = Clock(); let (gateway, adapter) = try host(clock)
        let first = call(gateway, "input", try input(adapter))
        XCTAssertEqual(first.value(for: "input_sequence"), .string("1"))
        XCTAssertEqual(first.value(for: "writer_id"), .string(adapter.principals.remoteWriterID))
        let staleGlobal = try adapter.discovery().latest_sequence
        let feedback = call(gateway, "feedback", [
            "expected": try .encoded(adapter.discovery().expected),
            "control_id": .string("button.1.1"), "kind": .string("indicator"), "value": .string("on")
        ])
        XCTAssertEqual(feedback.value(for: "input_sequence"), .string("1"))
        var legacy = try input(adapter, value: .number(0))
        legacy.removeValue(forKey: "expected_input_sequence"); legacy["expected_sequence"] = .string(staleGlobal)
        _ = call(gateway, "input", legacy, error: "stale_sequence")
        let next = call(gateway, "input", try input(adapter, value: .number(0), sequence: "1"))
        XCTAssertEqual(next.value(for: "input_sequence"), .string("2"))
        var forged = try input(adapter)
        forged["writer_id"] = .string(adapter.principals.systemWriterID)
        _ = call(gateway, "input", forged, error: "invalid_argument")
        gateway.session.withWriteOrigin(.software) { gateway.session.turn(.pushEncoder(group: 1, 2), by: 1) }
        let current = try adapter.discovery()
        let page = try adapter.execute(.events(instanceID: current.expected.instance_id, epoch: current.expected.epoch,
                                               afterSequence: "0", limit: 1024), gateway: gateway)
            .decoded(ControlEventPage.self)
        XCTAssertEqual(page.events.last?.writer_id, adapter.principals.interfaceWriterID)
        _ = call(gateway, "input", try input(adapter, control: "button.1.3", value: .bool(true), hold: 0.2))
        let heldSequence = try adapter.discovery().latest_input_sequence!
        clock.time += 0.2
        let expired = try adapter.processHoldExpiries()
        XCTAssertEqual(expired.last?.writer_id, adapter.principals.systemWriterID)
        XCTAssertNotEqual(expired.last?.writer_id, adapter.principals.remoteWriterID)
        _ = call(gateway, "input", try input(adapter, control: "button.1.3", value: .bool(true),
                                             sequence: heldSequence), error: "stale_input_sequence")
    }

    func testCategoryBudgetsDoNotBorrowAndLegacyAggregateRemainsSeparate() throws {
        let clock = Clock()
        let limits = BCRSurfaceControlAdapter.WriteLimits(inputPerWindow: 3, feedbackPerWindow: 1,
                                                          renewPerWindow: 1, adminPerWindow: 1)
        let (gateway, adapter) = try host(clock, limits: limits, aggregate: 1)
        try gateway.consumeWrites(1)
        XCTAssertThrowsError(try gateway.consumeWrites(1))
        let discovery = try adapter.discovery()
        XCTAssertEqual(discovery.write_limits, limits)
        XCTAssertTrue(discovery.profile.capabilities.contains("writes.independent_limits"))
        func feedback(_ value: String = "on", error: String? = nil) throws {
            _ = call(gateway, "feedback", ["expected": try .encoded(adapter.discovery().expected),
                                           "control_id": .string("button.1.1"), "kind": .string("indicator"),
                                           "value": .string(value)], error: error)
        }
        try feedback("invalid", error: "invalid_value")
        try feedback(); try feedback(error: "rate_limited")
        _ = call(gateway, "input", try input(adapter, control: "button.1.3", value: .bool(true), hold: 0.5))
        func renew(_ error: String? = nil) throws {
            _ = call(gateway, "renew", ["expected": try .encoded(adapter.discovery().expected),
                                        "control_id": .string("button.1.3"), "hold_s": .double(0.5)], error: error)
        }
        try renew(); try renew("rate_limited")
        _ = call(gateway, "input", try input(adapter, control: "button.1.3", value: .bool(false)))
        _ = call(gateway, "input", try input(adapter, control: "button.1.3", value: .bool(true), hold: 0.5))
        _ = call(gateway, "input", try input(adapter), error: "rate_limited")
        clock.time = 10.5
        XCTAssertEqual(try adapter.processHoldExpiries().last?.writer_id, adapter.principals.systemWriterID)
        _ = call(gateway, "input", try input(adapter), error: "rate_limited")
        clock.time = 9
        var rollback = try input(adapter)
        rollback["expected"] = try .encoded(discovery.expected)
        _ = call(gateway, "input", rollback, error: "invalid_time")
        clock.time = 10.6
        _ = call(gateway, "input", try input(adapter), error: "rate_limited")
        clock.time = 11
        _ = call(gateway, "input", try input(adapter))
        func reset(_ error: String? = nil) throws {
            let d = try adapter.discovery()
            _ = call(gateway, "reset", ["expected": try .encoded(d.expected),
                                        "expected_sequence": .string(d.latest_sequence)], error: error)
        }
        try reset(); try reset("rate_limited")
        try feedback()
    }

    func testCategoryLimitParsingIsStrictAndDefaultKeepsAggregateDescription() throws {
        let limits = try BCRSurfaceControlAdapter.parseWriteLimits("input=60,feedback=20,renew=60,admin=5")
        XCTAssertEqual(limits.input_per_window, 60)
        for invalid in ["input=1", "input=1,feedback=1,renew=1,admin=0", "input=1,feedback=1,renew=1,admin=10001",
                        "input=1,feedback=1,renew=1,admin=1,input=2", "input=1,feedback=1,renew=1,other=1",
                        "input=1,feedback=1,renew=1,admin=+1", "input=1,feedback=1,renew=1,admin=1.0",
                        "input=1,feedback=1,renew=1,admin=1,"]
        {
            XCTAssertThrowsError(try BCRSurfaceControlAdapter.parseWriteLimits(invalid), invalid)
        }
        let (_, adapter) = try host(Clock())
        XCTAssertNil(try adapter.discovery().write_limits)
        XCTAssertFalse(try adapter.discovery().profile.capabilities.contains("writes.independent_limits"))
    }
}
