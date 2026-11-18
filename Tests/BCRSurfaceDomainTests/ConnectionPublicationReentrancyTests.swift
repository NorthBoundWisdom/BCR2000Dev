import BCRFoundation
import BCRSurfaceDomain
import Foundation
import XCTest

@MainActor
final class ConnectionPublicationReentrancyTests: XCTestCase {
    private final class Device: SurfaceDevice {
        var connection: MIDIConnectionSnapshot = {
            var value = MIDIConnectionSnapshot(connectedSource: "fixture", connectedDestination: "fixture")
            value.connectedSourceID = 1; value.connectedDestinationID = 1
            return value
        }()

        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        var sends: [(route: Int32?, message: MIDIVoiceMessage)] = []
        var onSend: (() -> Void)?
        func send(_ message: MIDIVoiceMessage) throws {
            sends.append((connection.connectedDestinationID, message)); onSend?()
        }

        func route(_ id: Int32) {
            connection.connectedSourceID = id; connection.connectedDestinationID = id
            onConnection?(connection)
        }
    }

    private func fixture(lifecycle: Bool = false, secondControl: Bool = false) -> (SurfaceSession, Device) {
        let device = Device(), control = BCRControlID.encoder(row: 1, 1)
        var map = HardwareMap(entries: [.init(control: control,
                                              midi: .init(kind: .controlChange, channel: 0, number: 81))])
        var configuration = SurfaceConfiguration(name: "fixture", parameters: [.init(id: "p", name: "p")],
                                                 assignments: [.init(control: control, target: .parameter("p"))])
        if secondControl {
            try! map.bind(.encoder(row: 1, 2), to: .init(kind: .controlChange, channel: 0, number: 82))
            try! configuration.addParameter(.init(id: "q", name: "q"))
            try! configuration.assign(.init(control: .encoder(row: 1, 2), target: .parameter("q")))
        }
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: map, configuration: configuration,
                                     hardwareLifecycleFeedback: lifecycle,
                                     now: { Date(timeIntervalSinceReferenceDate: 100) },
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.selectSource(.hardware)
        device.sends.removeAll()
        return (session, device)
    }

    func testQueueObserverDisplayCannotAttributeNewTransportToOldEndpoint() async throws {
        let (session, device) = fixture()
        var armed = true, callbackError: String?
        _ = session.observeFeedbackQueue { _ in
            guard armed else { return }; armed = false
            do { try session.setHardwareDisplayFeedback(.encoder(row: 1, 1), rawValue: 64) }
            catch { callbackError = (error as? ProviderDomainError)?.code ?? String(describing: error) }
        }
        device.route(2)
        let event = session.events.last { $0.delivery == .sent }
        print(
            "J3 publication display actual_routes=\(device.sends.map(\.route)) event_endpoint=\(String(describing: event?.endpoint?.endpointID)) callback_error=\(String(describing: callbackError)) canonical_route=\(String(describing: session.connection.connectedDestinationID))"
        )
        XCTAssertTrue(device.sends.isEmpty)
        XCTAssertNil(event)
        XCTAssertEqual(callbackError, "permission_denied")
    }

    func testNewerRouteFromQueueObserverCannotBeOverwrittenByOuterSnapshot() async throws {
        let (session, device) = fixture()
        var armed = true
        _ = session.observeFeedbackQueue { _ in
            guard armed else { return }; armed = false; device.route(3)
        }
        device.route(2)
        print(
            "J3 publication nested actual_route=\(String(describing: device.connection.connectedDestinationID)) canonical_route=\(String(describing: session.connection.connectedDestinationID))"
        )
        XCTAssertEqual(session.connection.connectedDestinationID, device.connection.connectedDestinationID)
    }

    func testJournalResetObserverDisplayCannotAttributeNewTransportToOldEndpoint() async throws {
        let (session, device) = fixture()
        var armed = true, errorCode: String?
        _ = session.inputEvents.observe { _ in
            guard armed else { return }; armed = false
            do { try session.setHardwareDisplayFeedback(.encoder(row: 1, 1), rawValue: 64) }
            catch { errorCode = (error as? ProviderDomainError)?.code ?? String(describing: error) }
        }
        device.route(2)
        XCTAssertTrue(device.sends.isEmpty)
        XCTAssertEqual(errorCode, "permission_denied")
    }

    func testNewerRouteFromJournalResetObserverCannotBeOverwritten() async throws {
        let (session, device) = fixture()
        var armed = true, innerEpoch: String?
        _ = session.inputEvents.observe { _ in
            guard armed else { return }; armed = false; device.route(3)
            innerEpoch = session.inputEvents.generation
        }
        device.route(2)
        XCTAssertEqual(session.connection.connectedDestinationID, device.connection.connectedDestinationID)
        XCTAssertEqual(session.connectionGeneration, 2)
        XCTAssertEqual(session.inputEvents.generation, innerEpoch)
        let events = session.inputEvents.snapshot().objectValue?["events"]?.arrayValue ?? []
        XCTAssertEqual(events.compactMap { $0.objectValue?["kind"]?.stringValue }, ["context.changed"])
        XCTAssertEqual(session.inputEvents.sequence, 1)
    }

    func testQueueObserverFlushCannotSendOldPendingToNewRoute() async throws {
        let (session, device) = fixture()
        try session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        session.setParameter("p", to: 50)
        XCTAssertEqual(session.pendingFeedbackCount, 1)
        var armed = true
        _ = session.observeFeedbackQueue { _ in
            guard armed else { return }; armed = false; session.flushFeedback()
        }
        device.route(2)
        XCTAssertTrue(device.sends.isEmpty)
        XCTAssertEqual(session.pendingFeedbackCount, 0)
        session.setParameter("p", to: 60)
        session.flushFeedback()
        XCTAssertEqual(device.sends.count, 1)
        XCTAssertEqual(device.sends.last?.route, 2)
        XCTAssertEqual(session.events.last { $0.delivery == .sent }?.endpoint?.endpointID, "2")
    }

    func testStableRouteAfterPublicationStillAcceptsDisplay() async throws {
        let (session, device) = fixture()
        device.route(2)
        try session.setHardwareDisplayFeedback(.encoder(row: 1, 1), rawValue: 64)
        XCTAssertEqual(device.sends.count, 1)
        XCTAssertEqual(device.sends.last?.route, 2)
        XCTAssertEqual(session.events.last { $0.delivery == .sent }?.endpoint?.endpointID, "2")
    }

    func testConnectedEventNewerRouteCancelsOuterLifecycleAndPublish() async throws {
        let (session, device) = fixture(lifecycle: true)
        var armed = true, publishes = 0
        session.onChange = { publishes += 1 }
        session.onEvent = { event in
            if case .connected = event, armed { armed = false; device.route(3) }
        }
        device.route(2)
        XCTAssertEqual(session.connection.connectedDestinationID, 3)
        XCTAssertEqual(device.sends.count, 1)
        XCTAssertTrue(device.sends.allSatisfy { $0.route == 3 })
        XCTAssertEqual(publishes, 1)
    }

    func testRouteChangeInsideLifecycleSendCannotResumeOldBatchOnNewRoute() async throws {
        let (session, device) = fixture(lifecycle: true, secondControl: true)
        device.onSend = { device.onSend = nil; device.route(3) }
        device.route(2)
        XCTAssertEqual(session.connection.connectedDestinationID, 3)
        XCTAssertEqual(device.sends.count, 3)
        XCTAssertEqual(device.sends.map(\.route), [2, 3, 3])
    }

    func testJournalObserverFlushRetainsPendingUntilEstablishedClearBoundary() async throws {
        let (session, device) = fixture()
        try session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        session.setParameter("p", to: 50)
        var armed = true, pendingBefore: Int?, pendingAfter: Int?
        _ = session.inputEvents.observe { _ in
            guard armed else { return }; armed = false
            pendingBefore = session.pendingFeedbackCount
            session.flushFeedback()
            pendingAfter = session.pendingFeedbackCount
        }
        device.route(2)
        XCTAssertEqual(pendingBefore, 1)
        XCTAssertEqual(pendingAfter, 1)
        XCTAssertTrue(device.sends.isEmpty)
        XCTAssertEqual(session.pendingFeedbackCount, 0)
    }

    func testUnpublishedHardwareOrdinaryFeedbackIsSuppressedWithoutChangingAuthority() async throws {
        let (session, device) = fixture()
        var armed = true
        _ = session.observeFeedbackQueue { _ in
            guard armed else { return }; armed = false; session.setParameter("p", to: 64)
        }
        device.route(2)
        XCTAssertEqual(session.engine.value(of: "p"), 64)
        XCTAssertTrue(device.sends.isEmpty)
        XCTAssertEqual(session.events.last { $0.message.dataValue == 64 }?.delivery, .suppressed)
        session.setParameter("p", to: 65)
        XCTAssertEqual(device.sends.count, 1)
        XCTAssertEqual(device.sends.last?.route, 2)
    }

    func testUnpublishedHardwareConnectionDoesNotSuppressMockFeedback() async throws {
        let (session, device) = fixture()
        session.selectSource(.mock)
        var armed = true
        _ = session.inputEvents.observe { _ in
            guard armed else { return }; armed = false; session.setParameter("p", to: 64)
        }
        let previous = session.events.count
        device.route(2)
        let feedback = session.events.dropFirst(previous).filter { $0.direction == .output }
        XCTAssertFalse(feedback.isEmpty)
        XCTAssertTrue(feedback.allSatisfy { $0.source == .mock && $0.delivery == .sent })
        XCTAssertTrue(device.sends.isEmpty)
        XCTAssertEqual(session.engine.value(of: "p"), 64)
    }

    func testSynchronizeLifecycleBatchCannotResumeAfterSynchronousRouteChange() async throws {
        let (session, device) = fixture(lifecycle: true, secondControl: true)
        device.onSend = { device.onSend = nil; device.route(2) }
        session.synchronize()
        XCTAssertEqual(device.sends.count, 3)
        XCTAssertEqual(device.sends.map(\.route), [1, 2, 2])
        XCTAssertEqual(session.connection.connectedDestinationID, 2)
    }

    func testUnchangedRouteLifecyclePreservesCompleteBatchAndHeadlessNeverSends() async throws {
        let (gui, device) = fixture(lifecycle: true, secondControl: true)
        gui.synchronize()
        XCTAssertEqual(device.sends.count, 2)
        XCTAssertEqual(device.sends.map(\.route), [1, 1])
        let (headless, silent) = fixture(lifecycle: false, secondControl: true)
        silent.route(2)
        headless.synchronize()
        XCTAssertTrue(silent.sends.isEmpty)
    }

    private func cosmeticNotification(_ device: Device, endpointList: Bool) {
        if endpointList {
            device.connection.sourceEndpoints.append(.init(id: 99, name: "unselected", provenance: .remoteVirtual))
            device.connection.destinationNames.append("unselected")
        } else { device.connection.lastError = "cosmetic diagnostic" }
        device.onConnection?(device.connection)
    }

    func testSameSemanticNotificationPreservesSynchronizeLifecycleBatch() async throws {
        for endpointList in [false, true] {
            let (session, device) = fixture(lifecycle: true, secondControl: true)
            let generation = session.inputEvents.generation
            let revision = session.connectionGeneration
            device.onSend = { device.onSend = nil; self.cosmeticNotification(device, endpointList: endpointList) }
            session.synchronize()
            XCTAssertEqual(device.sends.map(\.route), [1, 1])
            XCTAssertEqual(session.connectionGeneration, revision)
            XCTAssertEqual(session.inputEvents.generation, generation)
        }
    }

    func testSameSemanticNotificationInsideConnectBatchPreservesRemainingEffectsAndPublish() async throws {
        for endpointList in [false, true] {
            let (session, device) = fixture(lifecycle: true, secondControl: true)
            var publishes = 0
            session.onChange = { publishes += 1 }
            device.onSend = { device.onSend = nil; self.cosmeticNotification(device, endpointList: endpointList) }
            device.route(2)
            XCTAssertEqual(device.sends.map(\.route), [2, 2])
            XCTAssertEqual(publishes, 2)
            XCTAssertEqual(session.connectionGeneration, 1)
            XCTAssertEqual(session.connection.lastError, endpointList ? nil : "cosmetic diagnostic")
        }
    }

    func testSameSemanticNotificationFromConnectedEventPreservesLifecycleAndPublish() async throws {
        for endpointList in [false, true] {
            let (session, device) = fixture(lifecycle: true, secondControl: true)
            var armed = true, publishes = 0
            session.onChange = { publishes += 1 }
            session.onEvent = { event in
                if case .connected = event, armed {
                    armed = false; self.cosmeticNotification(device, endpointList: endpointList)
                }
            }
            device.route(2)
            XCTAssertEqual(device.sends.map(\.route), [2, 2])
            XCTAssertEqual(publishes, 2)
            XCTAssertEqual(session.connectionGeneration, 1)
            XCTAssertEqual(session.connection.lastError, endpointList ? nil : "cosmetic diagnostic")
        }
    }
}
