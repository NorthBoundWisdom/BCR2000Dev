import BCRFoundation
import BCRMCPAdapter
import BCRProviderMCPAdapter
import BCRSurfaceDomain
import Foundation
import SurfaceControlContracts
import BCRTestSupport
import XCTest

/// Contract 1.1 adoption in the BCR host (P2-B): vocabulary, deterministic revision, hold/renew/expiry.
@MainActor
final class SurfaceControlHoldTests: XCTestCase {
    final class Clock { var time: Double = 10 }
    @MainActor final class Timers {
        var pending: [(delay: Double, action: @MainActor () -> Void, id: Int)] = []
        var cancelled: Set<Int> = []
        var next = 0
        var live: [(delay: Double, action: @MainActor () -> Void, id: Int)] {
            pending.filter { !cancelled.contains($0.id) }
        }

        /// Runs the latest live timer once, as the main-actor task would, and retires it.
        func fire() {
            guard let timer = live.last else { return }
            cancelled.insert(timer.id)
            timer.action()
        }
    }

    let hold = BCRControlID.button(row: 1, 3)

    func host(clock: Clock = Clock(), timers: Timers = Timers(), allow: Bool = true)
        throws -> (MCPApplicationGateway, BCRSurfaceControlAdapter)
    {
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: session,
                                            permissions: .init(deviceControl: true, simulationControl: true),
                                            includeAgent: false)
        let adapter = try SurfaceControlMCPModule.install(
            on: gateway, instanceID: "fixture", permissions: .init(input: allow, feedback: true, reset: true),
            monotonic: { clock.time },
            holdScheduler: { delay, action in
                let id = timers.next; timers.next += 1
                timers.pending.append((delay, action, id))
                return { timers.cancelled.insert(id) }
            }
        )
        return (gateway, try XCTUnwrap(adapter))
    }

    func call(_ gateway: MCPApplicationGateway, _ name: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        let result = gateway.call("surface_control_" + name, arguments: .object(args))
        XCTAssertFalse(result.isError, "\(name): \(result.value)")
        return result.value
    }

    func code(_ gateway: MCPApplicationGateway, _ name: String, _ args: [String: JSONValue]) -> JSONValue? {
        let result = gateway.call("surface_control_" + name, arguments: .object(args))
        XCTAssertTrue(result.isError, name)
        return result.value.objectValue?["code"]
    }

    func discovery(_ gateway: MCPApplicationGateway) throws -> [String: JSONValue] {
        try XCTUnwrap(call(gateway, "discover").objectValue)
    }

    func press(_ gateway: MCPApplicationGateway, _ value: Bool, holdSeconds: Double? = 1,
               control: String = "button.1.3", encoding: String = "boolean") throws -> [String: JSONValue]
    {
        let current = try discovery(gateway)
        var args: [String: JSONValue] = ["expected": current["expected"]!,
                                         "expected_sequence": current["latest_sequence"]!,
                                         "control_id": .string(control), "encoding": .string(encoding),
                                         "value": encoding == "boolean" ? .bool(value) : .number(value ? 127 : 0)]
        if let holdSeconds { args["hold_s"] = .double(holdSeconds) }
        return args
    }

    func renewArgs(_ gateway: MCPApplicationGateway, _ seconds: Double = 1) throws -> [String: JSONValue] {
        ["expected": try discovery(gateway)["expected"]!, "control_id": .string("button.1.3"),
         "hold_s": .double(seconds)]
    }

    func testToggleAndUnboundButtonsDoNotOfferLeases() throws {
        let (gateway, adapter) = try host()
        for id in ["button.1.1", "button.1.2", "button.2.1"] {
            let control = try XCTUnwrap(try adapter.discovery().profile.controls.first { $0.id == id })
            XCTAssertNil(control.hold, id)
            XCTAssertEqual(code(gateway, "input", try press(gateway, true, control: id)),
                           .string(id == "button.2.1" ? "permission_denied" : "unsupported_hold"))
        }
        var protected = try XCTUnwrap(gateway.session.engine.configuration.parameter("simulation.hold"))
        protected.externallyProtected = true
        try gateway.session.updateParameter(protected)
        let blocked = try XCTUnwrap(try adapter.discovery().profile.controls.first { $0.id == "button.1.3" })
        XCTAssertEqual(blocked.accepts_input, false)
        XCTAssertNil(blocked.hold)
    }

    func testProfileUsesSharedVocabularyDeterministicRevisionAndButtonHold() throws {
        let (gateway, adapter) = try host()
        let discovery = try adapter.discovery()
        XCTAssertEqual(discovery.contract_version, "1.3")
        XCTAssertEqual(discovery.profile.version, "1.3")
        XCTAssertEqual(discovery.profile.capabilities, [
            "simulation", "controls.stable_ids", "feedback.unsequenced", "controls.input_declared",
            "input.independent_sequence", "events.writer_id", "input.absolute",
            "input.button",
            "input.hold", "feedback.value",
            "feedback.indicator", "x.bcr.display_only_feedback", "x.bcr.explicit_input_permissions",
            "x.bcr.indicator_blink_static"
        ])
        XCTAssertEqual(discovery.expected.mapping_revision, discovery.profile.mappingRevision)
        XCTAssertEqual(discovery.expected.mapping_revision.count, 16)
        XCTAssertEqual(discovery.expected.mapping_revision, "ef0e106767594759")
        let leased = discovery.profile.controls.filter { $0.hold != nil }
        XCTAssertEqual(leased.map(\.id), ["button.1.3"])
        XCTAssertTrue(leased.allSatisfy {
            $0.accepts_input == true && $0.hold == ControlHold(restValue: .bool(false),
                                                               maxHoldSeconds: BCRSurfaceControlAdapter
                                                                   .maximumButtonHoldSeconds)
        })
        XCTAssertTrue(discovery.profile.controls.filter { $0.input_kind != .button }.allSatisfy { $0.hold == nil })
        // Same mapping in another process or after reset: same revision, different epoch.
        let (other, otherAdapter) = try host()
        XCTAssertEqual(try otherAdapter.discovery().expected.mapping_revision, discovery.expected.mapping_revision)
        let reset = try call(other, "reset", ["expected": try .encoded(otherAdapter.discovery().expected),
                                              "expected_sequence": .string("0")])
        XCTAssertEqual(reset.objectValue?["expected"]?.objectValue?["mapping_revision"],
                       .string(discovery.expected.mapping_revision))
        // Relative encoders appear only when configured, and then the capability follows.
        try gateway.session.setAssignment(.init(control: .encoder(row: 1, 1), target: .parameter("simulation.arm"),
                                                encoderMode: .relative1), for: .encoder(row: 1, 1))
        let relative = try adapter.discovery()
        XCTAssertTrue(relative.profile.capabilities.contains("input.relative"))
        XCTAssertNotEqual(relative.expected.mapping_revision, discovery.expected.mapping_revision)
        XCTAssertTrue(gateway.toolDefinitions.contains { $0.objectValue?["name"] == .string("surface_control_renew") })
    }

    func testLeaseRenewAndSchedulerExpiryReturnTheMockToRest() throws {
        let clock = Clock(); let timers = Timers()
        let (gateway, _) = try host(clock: clock, timers: timers)
        let held = try call(gateway, "input", press(gateway, true))
        XCTAssertEqual(held.objectValue?["disposition"], .string("accepted"))
        XCTAssertEqual(held.objectValue?["hold_deadline"]?.finiteNumber, 11)
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.hold"), 1)
        XCTAssertEqual(timers.live.map(\.delay), [1])
        clock.time = 10.5
        let renewed = try call(gateway, "renew", renewArgs(gateway)).objectValue!
        XCTAssertEqual(renewed["hold_deadline"]?.finiteNumber, 11.5)
        XCTAssertEqual(renewed["server_time"]?.finiteNumber, 10.5)
        XCTAssertEqual(try discovery(gateway)["latest_sequence"], .string("1")) // silent: no sequence/event
        XCTAssertEqual(timers.live.map(\.delay), [1])
        clock.time = 11.5
        timers.fire() // the host timer fires without any request
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.hold"), 0)
        XCTAssertEqual(gateway.session.mock.inputDataValues[hold], 0)
        let current = try discovery(gateway)
        XCTAssertEqual(current["latest_sequence"], .string("2"))
        let page = try call(gateway, "events", ["instance_id": .string("fixture"),
                                                "epoch": current["expected"]!.objectValue!["epoch"]!,
                                                "after_sequence": .string("1"), "limit": .number(8)])
        let expiry = try XCTUnwrap(page.objectValue?["events"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(expiry["reason"], .string("hold_expired"))
        XCTAssertEqual(expiry["origin"], .string("remote"))
        XCTAssertEqual(expiry["value"], .bool(false))
        XCTAssertEqual(expiry["mapped_value"], .number(0))
        XCTAssertEqual(page.objectValue?["events"]?.arrayValue?.count, 1) // observer did not double record
        clock.time = 11.6
        XCTAssertEqual(code(gateway, "renew", try renewArgs(gateway)), .string("hold_expired"))
        XCTAssertTrue(timers.live.isEmpty)
    }

    func testRequestsProcessDueLeasesFirstEvenWithoutTheTimer() throws {
        let clock = Clock()
        let (gateway, adapter) = try host(clock: clock)
        _ = try call(gateway, "input", press(gateway, true, holdSeconds: 0.5))
        clock.time = 12 // timer has not fired (the scheduler is a recorder)
        XCTAssertEqual(adapter.nextHoldDeadline, 10.5)
        let snapshot = try call(gateway, "snapshot", ["instance_id": .string("fixture")]).objectValue!
        XCTAssertEqual(snapshot["latest_sequence"], .string("2"))
        XCTAssertEqual(snapshot["inputs"]?.objectValue?["button.1.3"], .bool(false))
        XCTAssertNil(snapshot["holds"])
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.hold"), 0)
    }

    func testPendingExpiryWithoutAutomaticProcessingFailsClosedWithPassThroughCode() throws {
        let clock = Clock()
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: session, permissions: .init(deviceControl: true),
                                            includeAgent: false)
        let adapter = try BCRSurfaceControlAdapter(surface: session, instanceID: "fixture",
                                                   permissions: .init(input: true), monotonic: { clock.time },
                                                   holdScheduler: { _, _ in {} }, automaticHoldExpiry: false)
        let discovery = try adapter.discovery()
        _ = try adapter.execute(.input(.init(expected: discovery.expected, expectedSequence: "0",
                                             controlID: "button.1.3", encoding: "boolean", value: .bool(true),
                                             holdSeconds: 1)), gateway: gateway)
        clock.time = 11
        XCTAssertThrowsError(try adapter.execute(.snapshot(instanceID: "fixture"), gateway: gateway)) {
            XCTAssertEqual(BCRSurfaceControlAdapter.failureCode($0), "hold_expiry_pending")
        }
        XCTAssertEqual(session.engine.value(of: "simulation.hold"), 1)
        XCTAssertEqual(try adapter.processHoldExpiries().map(\.reason), ["hold_expired"])
        XCTAssertEqual(session.engine.value(of: "simulation.hold"), 0)
    }

    func testRenewPermissionsBudgetAndUnsupportedHold() throws {
        let (denied, _) = try host(allow: false)
        XCTAssertEqual(code(denied, "renew", try renewArgs(denied)), .string("permission_denied"))
        let (gateway, _) = try host()
        XCTAssertEqual(code(gateway, "renew", try renewArgs(gateway)), .string("hold_expired"))
        let encoder = try press(gateway, true, control: "pushEncoder.1.1", encoding: "scalar")
        XCTAssertEqual(code(gateway, "input", encoder), .string("unsupported_hold"))
        XCTAssertEqual(try discovery(gateway)["latest_sequence"], .string("0"))
        XCTAssertEqual(code(gateway, "renew", ["expected": try discovery(gateway)["expected"]!,
                                               "control_id": .string("button.1.3"), "hold_s": .double(5.5)]),
                       .string("invalid_argument"))
        gateway.permissions.writesPerSecond = 1
        _ = try call(gateway, "input", press(gateway, true))
        XCTAssertEqual(code(gateway, "renew", try renewArgs(gateway)), .string("rate_limited"))
    }

    func testRestValueClearsLeaseAndContextChangeReleasesHeldButton() throws {
        let clock = Clock(); let timers = Timers()
        let (gateway, _) = try host(clock: clock, timers: timers)
        _ = try call(gateway, "input", press(gateway, true))
        let release = try call(gateway, "input", press(gateway, false, holdSeconds: nil))
        XCTAssertEqual(release.objectValue?["disposition"], .string("accepted"))
        XCTAssertTrue(timers.live.isEmpty)
        XCTAssertEqual(code(gateway, "renew", try renewArgs(gateway)), .string("hold_expired"))
        _ = try call(gateway, "input", press(gateway, true))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.hold"), 1)
        let before = try discovery(gateway)
        try gateway.session.setAssignment(nil, for: .button(row: 1, 2)) // mapping changes, lease is revoked
        let after = try discovery(gateway)
        XCTAssertNotEqual(after["expected"], before["expected"])
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.hold"), 0)
        XCTAssertEqual(gateway.session.mock.inputDataValues[hold], 0)
        let snapshot = try call(gateway, "snapshot", ["instance_id": .string("fixture")]).objectValue!
        XCTAssertNil(snapshot["holds"])
        XCTAssertEqual(snapshot["inputs"]?.objectValue?["button.1.3"], .bool(false))
        XCTAssertTrue(timers.live.isEmpty)
        // A source change while held defers the release until the Mock is active again.
        _ = try call(gateway, "input", press(gateway, true))
        gateway.session.selectSource(.hardware)
        XCTAssertEqual(code(gateway, "discover", [:]), .string("unsupported_source"))
        gateway.session.selectSource(.mock)
        _ = try discovery(gateway)
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.hold"), 0)
        XCTAssertEqual(gateway.session.mock.inputDataValues[hold], 0)
    }

    func testAnyToolCallReleasesDueLeasesBeforeItRuns() throws {
        // A queue of unrelated or invalid requests cannot postpone an expiry behind itself: each
        // call first releases what is already due, so the delay is at most the request in flight.
        let clock = Clock()
        let (gateway, _) = try host(clock: clock)
        _ = try call(gateway, "input", press(gateway, true, holdSeconds: 0.5))
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.hold"), 1)
        clock.time = 10.5
        XCTAssertTrue(gateway.call("no_such_tool").isError) // not a surface tool, and it fails
        XCTAssertEqual(gateway.session.engine.value(of: "simulation.hold"), 0)
        XCTAssertEqual(gateway.session.mock.inputDataValues[hold], 0)
        let current = try discovery(gateway)
        XCTAssertEqual(current["latest_sequence"], .string("2"))
        let page = try call(gateway, "events", ["instance_id": .string("fixture"),
                                                "epoch": current["expected"]!.objectValue!["epoch"]!,
                                                "after_sequence": .string("1"), "limit": .number(8)])
        let expiry = try XCTUnwrap(page.objectValue?["events"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(expiry["reason"], .string("hold_expired"))
        XCTAssertEqual(expiry["time"]?.finiteNumber, 10.5) // recorded at the preflight, not later
    }

    /// Records what the default scheduler asks the clock for; `release` lets the sleep return.
    @MainActor final class SleepRecorder {
        var requests: [(deadline: SuspendingClock.Instant, tolerance: Duration)] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
        func release() { for waiter in waiters { waiter.resume() }; waiters = [] }
    }

    private func recordingScheduler(now: SuspendingClock.Instant, recorder: SleepRecorder)
        -> BCRSurfaceControlAdapter.HoldScheduler
    {
        BCRSurfaceControlAdapter.holdScheduler(now: { now }, sleep: { deadline, tolerance in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    recorder.requests.append((deadline, tolerance))
                    recorder.waiters.append(continuation)
                }
            }
        })
    }

    private func occupyMainActor(for seconds: TimeInterval) {
        // Synchronous by design: delay the new scheduler Task before its first actor turn.
        Thread.sleep(forTimeInterval: seconds)
    }

    func testSchedulerDeadlineIsFixedWhenScheduledNotWhenItsTaskStarts() async throws {
        let recorder = SleepRecorder()
        let start = SuspendingClock().now
        var fired = 0
        let cancel = recordingScheduler(now: start, recorder: recorder)(0.2) { fired += 1 }
        defer { cancel() }
        // However long the actor stays busy before the task's first turn, the deadline was fixed
        // at scheduling time, so queueing never starts a fresh 200 ms wait.
        occupyMainActor(for: 0.05)
        try await waitUntil("the scheduler to request its sleep") { recorder.requests.count == 1 }
        XCTAssertEqual(recorder.requests[0].deadline, start.advanced(by: .milliseconds(201)))
        XCTAssertEqual(fired, 0)
        recorder.release()
        try await waitUntil("the hold action to run") { fired == 1 }
    }

    func testSchedulerToleranceDoesNotGrowWithTheLeaseLength() async throws {
        // Without an explicit tolerance the runtime may coalesce a sleep by a fraction of its length.
        let recorder = SleepRecorder()
        let start = SuspendingClock().now
        let scheduler = recordingScheduler(now: start, recorder: recorder)
        let cancels = [0.2, 2.0, BCRSurfaceControlAdapter.maximumButtonHoldSeconds].map { scheduler($0) {} }
        defer { cancels.forEach { $0() } }
        try await waitUntil("three sleep requests") { recorder.requests.count == 3 }
        XCTAssertEqual(recorder.requests.map(\.tolerance), Array(repeating: .milliseconds(2), count: 3))
        XCTAssertEqual(recorder.requests.map(\.deadline).sorted(),
                       [201, 2001, 5001].map { start.advanced(by: .milliseconds($0)) })
        XCTAssertEqual(BCRSurfaceControlAdapter.holdTimerTolerance, .milliseconds(2))
    }

    func testCancelledHoldNeverRunsEvenIfItsSleepReturns() async throws {
        let recorder = SleepRecorder()
        var fired = 0
        let cancel = recordingScheduler(now: SuspendingClock().now, recorder: recorder)(0.2) { fired += 1 }
        try await waitUntil("the scheduler to request its sleep") { recorder.requests.count == 1 }
        cancel()
        recorder.release()
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(fired, 0)
    }

    func testRealSchedulerRecordsExpiryAfterTheDeadline() async throws {
        // Real clock, end to end through the adapter. The exact lag depends on machine load, so this
        // checks only order and that the timer itself (no request in between) recorded the event; the
        // requested tolerance is checked exactly above.
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: session, permissions: .init(deviceControl: true),
                                            includeAgent: false)
        _ = try SurfaceControlMCPModule.install(on: gateway, instanceID: "fixture", permissions: .init(input: true))
        let held = try call(gateway, "input", press(gateway, true, holdSeconds: 0.2)).objectValue!
        let deadline = try XCTUnwrap(held["hold_deadline"]?.finiteNumber)
        try await waitUntil("the lease to expire") { session.engine.value(of: "simulation.hold") == 0 }
        let current = try discovery(gateway)
        let page = try call(gateway, "events", ["instance_id": .string("fixture"),
                                                "epoch": current["expected"]!.objectValue!["epoch"]!,
                                                "after_sequence": .string("1"), "limit": .number(8)])
        let expiry = try XCTUnwrap(page.objectValue?["events"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(expiry["reason"], .string("hold_expired"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(expiry["time"]?.finiteNumber), deadline)
    }

    func testRealSchedulerExpiresAShortLease() async throws {
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(),
                                     configuration: SurfaceControlMCPModule.simulationConfiguration(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let gateway = MCPApplicationGateway(session: session, permissions: .init(deviceControl: true),
                                            includeAgent: false)
        _ = try SurfaceControlMCPModule.install(on: gateway, instanceID: "fixture", permissions: .init(input: true))
        _ = try call(gateway, "input", press(gateway, true, holdSeconds: 0.2))
        XCTAssertEqual(session.engine.value(of: "simulation.hold"), 1)
        try await waitUntil("the lease to expire") { session.engine.value(of: "simulation.hold") == 0 }
        XCTAssertEqual(try discovery(gateway)["latest_sequence"], .string("2"))
    }
}
