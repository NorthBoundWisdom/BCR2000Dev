import BCRFoundation
@testable import BCRSurfaceDomain
import BCRMCPAdapter
import BCRProviderMCPAdapter
import Foundation
import SurfaceControlContracts
import XCTest

@MainActor
final class DisplayTransactionReentrancyTests: XCTestCase {
    private let one = BCRControlID.encoder(row: 1, 1)
    private let two = BCRControlID.encoder(row: 1, 2)
    private let time = Date(timeIntervalSinceReferenceDate: 1000)
    private final class Device: SurfaceDevice {
        var connection: MIDIConnectionSnapshot = {
            var c = MIDIConnectionSnapshot(connectedSource: "fixture", connectedDestination: "fixture")
            c.connectedSourceID = 1; c.connectedDestinationID = 1; return c
        }()

        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        var onSend: ((MIDIVoiceMessage) -> Void)?
        var reject64 = false
        var rejectValues: Set<UInt16> = []
        var attempts: [(MIDIVoiceMessage, Bool)] = []
        func send(_ message: MIDIVoiceMessage) throws {
            let reject = (reject64 && message.controlID.number == 81 && message.dataValue == 64) || rejectValues
                .contains(message.dataValue)
            attempts.append((message, !reject))
            onSend?(message)
            if reject { throw MIDIEncodingError.invalidMessage }
        }

        func route(_ id: Int32) {
            connection.connectedSourceID = id; connection.connectedDestinationID = id
            onConnection?(connection)
        }
    }

    private func fixture(bound: Bool = true) -> (SurfaceSession, Device) {
        let d = Device()
        let map = HardwareMap(entries: [
            .init(control: one, midi: .init(kind: .controlChange, channel: 0, number: 81)),
            .init(control: two, midi: .init(kind: .controlChange, channel: 0, number: 82))
        ])
        let config = SurfaceConfiguration(
            name: "fixture",
            parameters: [.init(id: "p", name: "p"), .init(id: "q", name: "q")],
            assignments: bound ? [
                .init(control: one, target: .parameter("p")),
                .init(control: two, target: .parameter("q"))
            ] : []
        )
        let time = time
        let s = SurfaceSession(hardwareDevice: d, hardwareMap: map, configuration: config,
                               hardwareLifecycleFeedback: false, now: { time }, saveHardwareMap: { _ in },
                               saveConfiguration: { _ in })
        s.selectSource(.hardware)
        return (s, d)
    }

    private func projected(_ s: SurfaceSession, _ control: BCRControlID) throws -> UInt16 {
        var copy = s.engine
        let address = try XCTUnwrap(copy.hardwareMap.midi(for: control))
        return try XCTUnwrap(copy.fullFeedback(at: time).compactMap { effect -> MIDIVoiceMessage? in
            if case let .send(message) = effect { return message }; return nil
        }.first { $0.controlID == address }).dataValue
    }

    private func adapter(_ s: SurfaceSession) throws
        -> (BCRHardwareSurfaceControlAdapter, MCPApplicationGateway, ControlDiscovery)
    {
        let g = MCPApplicationGateway(session: s)
        let a = try BCRHardwareSurfaceControlAdapter(
            surface: s,
            instanceID: "audit",
            permissions: .init(feedback: true),
            monotonic: { 10 }
        )
        let d = try a.execute(.discover, gateway: g).decoded(ControlDiscovery.self)
        return (a, g, d)
    }

    private func update(_ expected: ControlExpected, value: Int,
                        control: String = "encoder.1.1") -> ControlToolRequest
    {
        .feedback(.init(expected: expected, controlID: control, kind: "value", value: .number(value)))
    }

    func testSameScopeFailureRestoresOnlyUnacceptedDisplay() async throws {
        let (s, d) = fixture()
        try s.setHardwareDisplayFeedback(one, rawValue: 32)
        d.reject64 = true
        XCTAssertThrowsError(try s.setHardwareDisplayFeedback(one, rawValue: 64))
        XCTAssertEqual(try projected(s, one), 32)
        XCTAssertEqual(s.engine.value(of: "p"), 0)
    }

    func testRouteChangeFailureCannotRestoreOldEcho() async throws {
        let (s, d) = fixture()
        try s.setHardwareDisplayFeedback(one, rawValue: 32)
        let old = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 32)
        XCTAssertTrue(s.engine.isFeedbackEcho(old, at: time))
        d.reject64 = true
        d.onSend = { _ in d.onSend = nil; d.route(2) }
        XCTAssertThrowsError(try s.setHardwareDisplayFeedback(one, rawValue: 64))
        XCTAssertEqual(s.connection.connectedSourceID, 2)
        XCTAssertFalse(s.engine.isFeedbackEcho(old, at: time))
    }

    func testSourceChangeFailureCannotRestoreHardwareEngineIntoMock() async throws {
        let (s, d) = fixture(bound: false)
        try s.setHardwareDisplayFeedback(one, rawValue: 32)
        d.reject64 = true
        d.onSend = { _ in d.onSend = nil; s.selectSource(.mock) }
        XCTAssertThrowsError(try s.setHardwareDisplayFeedback(one, rawValue: 64))
        XCTAssertEqual(s.source, .mock)
        XCTAssertEqual(s.engine.hardwareMap, s.mock.preset)
        XCTAssertEqual(s.engine.echoWindow, 0)
    }

    func testConfigurationAndValueReentrancySurviveFailedDisplay() async throws {
        for replace in [false, true] {
            let (s, d) = fixture(); d.reject64 = true
            d.onSend = { _ in
                d.onSend = nil
                if replace {
                    do { try s.replaceConfiguration(
                        .init(name: "new", parameters: [.init(id: "new", name: "new", defaultValue: 77)]),
                        persist: false
                    ) } catch { XCTFail("config fixture: \(error)") }
                } else { s.setParameter("p", to: 99) }
            }
            XCTAssertThrowsError(try s.setHardwareDisplayFeedback(one, rawValue: 64))
            XCTAssertEqual(s.engine.value(of: replace ? "new" : "p"), replace ? 77 : 99)
        }
    }

    func testNestedUnrelatedSuccessDoesNotPreventOwnFailureRollback() async throws {
        let (s, d) = fixture(); try s.setHardwareDisplayFeedback(one, rawValue: 32); d.reject64 = true
        var called = false
        _ = s.observeMonitor { event, _ in
            if event.delivery == .failed && !called {
                called = true
                do { try s.setHardwareDisplayFeedback(self.two, rawValue: 55) } catch { XCTFail("nested: \(error)") }
            }
        }
        XCTAssertThrowsError(try s.setHardwareDisplayFeedback(one, rawValue: 64))
        XCTAssertTrue(called)
        XCTAssertEqual(try projected(s, one), 32)
        XCTAssertEqual(try projected(s, two), 55)
    }

    func testFailedReceiptCannotBeEvictedByNestedMonitorTraffic() async throws {
        let (s, d) = fixture(); try s.setHardwareDisplayFeedback(one, rawValue: 32); d.reject64 = true
        var called = false
        _ = s.observeMonitor { event, _ in
            if event.delivery == .failed && !called {
                called = true
                for _ in 0 ..< 310 {
                    do { try s.setHardwareDisplayFeedback(self.two, rawValue: 55) } catch { XCTFail("nested: \(error)")
                    }
                }
            }
        }
        XCTAssertThrowsError(try s.setHardwareDisplayFeedback(one, rawValue: 64))
        XCTAssertTrue(called)
        XCTAssertFalse(s.events.contains { $0.delivery == .failed })
        XCTAssertEqual(try projected(s, one), 32)
        XCTAssertEqual(try projected(s, two), 55)
    }

    func testNestedSameControlDisplayKeepsNewOwnershipAfterOuterFailure() async throws {
        let (s, d) = fixture(); d.reject64 = true
        d.onSend = { message in
            if message.dataValue == 64 {
                d.onSend = nil
                do { try s.setHardwareDisplayFeedback(self.one, rawValue: 55) } catch { XCTFail("nested: \(error)") }
            }
        }
        XCTAssertThrowsError(try s.setHardwareDisplayFeedback(one, rawValue: 64))
        XCTAssertEqual(try projected(s, one), 55)
    }

    func testHardwareInputCommittedDuringDisplayIsNotLost() async throws {
        let (s, d) = fixture(); let (a, g, discovery) = try adapter(s)
        d.onSend = { message in
            if message.dataValue == 64 {
                d.onSend = nil; d.onMessages?([.controlChange(channel: 0, number: 81, value: 71)])
            }
        }
        _ = try a.execute(update(discovery.expected, value: 64), gateway: g)
        let snapshot = try a.execute(.snapshot(instanceID: "audit"), gateway: g).decoded(ControlSnapshot.self)
        XCTAssertEqual(snapshot.latest_input_sequence, "1")
        XCTAssertEqual(snapshot.inputs["encoder.1.1"], .number(71))
        let events = try a.execute(
            .events(instanceID: "audit", epoch: discovery.expected.epoch, afterSequence: discovery.latest_sequence,
                    limit: 1024),
            gateway: g
        ).decoded(ControlEventPage.self)
        XCTAssertTrue(events.events.contains { $0.kind == .input })
        XCTAssertTrue(events.events.contains { $0.kind == .feedback })
    }

    func testNestedFeedbackFromMonitorKeepsNewestCanonicalValueAndBothEvents() async throws {
        let (s, _) = fixture(); let (a, g, discovery) = try adapter(s)
        var called = false
        _ = s.observeMonitor { event, _ in
            if event.delivery == .sent && event.message.dataValue == 64 && !called {
                called = true
                do { _ = try a.execute(self.update(discovery.expected, value: 55), gateway: g) }
                catch { XCTFail("nested: \(error)") }
            }
        }
        _ = try a.execute(update(discovery.expected, value: 64), gateway: g)
        let snapshot = try a.execute(.snapshot(instanceID: "audit"), gateway: g).decoded(ControlSnapshot.self)
        XCTAssertEqual(snapshot.feedback["encoder.1.1"]?["value"], .number(55))
        let events = try a.execute(
            .events(instanceID: "audit", epoch: discovery.expected.epoch, afterSequence: discovery.latest_sequence,
                    limit: 1024),
            gateway: g
        ).decoded(ControlEventPage.self)
        XCTAssertEqual(events.events.filter { $0.kind == .feedback }.map(\.value), [.number(64), .number(55)])
    }

    func testNestedOtherControlFeedbackDuringSendIsNotLost() async throws {
        let (s, d) = fixture(); let (a, g, discovery) = try adapter(s)
        d.onSend = { message in
            if message.dataValue == 64 {
                d.onSend = nil
                do { _ = try a.execute(self.update(discovery.expected, value: 55, control: "encoder.1.2"), gateway: g) }
                catch { XCTFail("nested: \(error)") }
            }
        }
        _ = try a.execute(update(discovery.expected, value: 64), gateway: g)
        let snapshot = try a.execute(.snapshot(instanceID: "audit"), gateway: g).decoded(ControlSnapshot.self)
        XCTAssertEqual(snapshot.feedback["encoder.1.1"]?["value"], .number(64))
        XCTAssertEqual(snapshot.feedback["encoder.1.2"]?["value"], .number(55))
        let events = try a.execute(
            .events(instanceID: "audit", epoch: discovery.expected.epoch, afterSequence: discovery.latest_sequence,
                    limit: 1024),
            gateway: g
        ).decoded(ControlEventPage.self)
        XCTAssertEqual(events.events.filter { $0.kind == .feedback }.count, 2)
    }

    func testNewSameValueDisplayOwnsProjectionDespiteOuterFailure() async throws {
        let (s, d) = fixture(); d.reject64 = true
        d.onSend = { _ in
            d.onSend = nil; d.reject64 = false
            do { try s.setHardwareDisplayFeedback(self.one, rawValue: 64) } catch { XCTFail("nested: \(error)") }
        }
        XCTAssertThrowsError(try s.setHardwareDisplayFeedback(one, rawValue: 64))
        XCTAssertEqual(try projected(s, one), 64)
        XCTAssertEqual(d.attempts.map(\.1), [false, true])
    }

    func testAcceptedOldEpochOutputFailsTransactionWithoutNewEpochFeedback() async throws {
        let (s, d) = fixture(); let (a, g, discovery) = try adapter(s)
        d.onSend = { _ in d.onSend = nil; d.route(2) }
        XCTAssertThrowsError(try a.execute(update(discovery.expected, value: 64), gateway: g)) { error in
            XCTAssertEqual(BCRSurfaceControlAdapter.failureCode(error), "delivery_failed")
        }
        let snapshot = try a.execute(.snapshot(instanceID: "audit"), gateway: g).decoded(ControlSnapshot.self)
        XCTAssertNotEqual(snapshot.discovery.expected.epoch, discovery.expected.epoch)
        XCTAssertTrue(snapshot.feedback.isEmpty)
        XCTAssertEqual(d.attempts.filter(\.1).count, 1)
        XCTAssertTrue(s.events
            .contains { $0.delivery == .sent && $0.message.dataValue == 64 && $0.endpoint?.endpointID == "1" })
    }

    func testNewerSameControlSuccessDuringSendSupersedesOldCompletionWithoutStale() async throws {
        let (s, d) = fixture(); let (a, g, discovery) = try adapter(s)
        d.onSend = { _ in
            d.onSend = nil
            do { _ = try a.execute(self.update(discovery.expected, value: 55), gateway: g) }
            catch { XCTFail("nested: \(error)") }
        }
        XCTAssertThrowsError(try a.execute(update(discovery.expected, value: 64), gateway: g)) { error in
            XCTAssertEqual(BCRSurfaceControlAdapter.failureCode(error), "delivery_failed")
        }
        let snapshot = try a.execute(.snapshot(instanceID: "audit"), gateway: g).decoded(ControlSnapshot.self)
        XCTAssertEqual(snapshot.feedback["encoder.1.1"]?["value"], .number(55))
        XCTAssertEqual(try projected(s, one), 55)
        let events = try a.execute(
            .events(instanceID: "audit", epoch: discovery.expected.epoch, afterSequence: discovery.latest_sequence,
                    limit: 1024),
            gateway: g
        ).decoded(ControlEventPage.self)
        XCTAssertEqual(events.events.filter { $0.kind == .feedback }.map(\.value), [.number(55)])
        XCTAssertEqual(d.attempts.map { $0.0.dataValue }, [64, 55])
        XCTAssertTrue(s.events.contains { $0.delivery == .sent && $0.message.dataValue == 64 })
    }

    func testNewerFailedDisplayDoesNotSuppressOlderSuccessfulCompletion() async throws {
        let (s, d) = fixture(); let (a, g, discovery) = try adapter(s)
        d.rejectValues = [55]
        d.onSend = { _ in
            d.onSend = nil
            do {
                _ = try a.execute(self.update(discovery.expected, value: 55), gateway: g)
                XCTFail("Nested rejected output unexpectedly completed")
            } catch {}
        }
        _ = try a.execute(update(discovery.expected, value: 64), gateway: g)
        let snapshot = try a.execute(.snapshot(instanceID: "audit"), gateway: g).decoded(ControlSnapshot.self)
        XCTAssertEqual(snapshot.feedback["encoder.1.1"]?["value"], .number(64))
        XCTAssertEqual(try projected(s, one), 64)
        let events = try a.execute(
            .events(instanceID: "audit", epoch: discovery.expected.epoch, afterSequence: discovery.latest_sequence,
                    limit: 1024),
            gateway: g
        ).decoded(ControlEventPage.self)
        XCTAssertEqual(events.events.filter { $0.kind == .feedback }.map(\.value), [.number(64)])
        XCTAssertEqual(d.attempts.map(\.1), [true, false])
    }
}
