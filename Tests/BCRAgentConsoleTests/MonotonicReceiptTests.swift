import BCRAgentCore
import BCRPluginRuntime
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

private final class ReceiptWall: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSinceReferenceDate: 10_000)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func jump(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

// Deliberately synchronous: the regression needs IO to run while MainActor cannot deliver.
private func stallReceiptConsumer(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

@MainActor
private final class ReceiptDevice: SurfaceDevice {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func send(_ message: MIDIVoiceMessage) throws {}
}

@MainActor
private final class ReceiptCounts {
    var heartbeats = 0
    var samples = 0
    var captured: Double?
    var drops = 0
    var failure: String?
}

@MainActor
private final class DualReceiptTransport: MonotonicOutputTransport {
    var isConnected = false
    var onSamples: (@MainActor ([ParameterSample]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var onPolicySamples: (@MainActor ([SharedParameterSample]) -> Void)?
    var onPolicyHeartbeat: (@MainActor (Double) -> Void)?
    var onPolicyPeerReset: (@MainActor (Double) -> Void)?
    var pings = 0
    func start(host: String, port: UInt16) throws { isConnected = true; onConnection?(true, nil) }
    func ping(at now: Date) throws { XCTFail("Production cadence must not use wall time") }
    func ping(atMonotonic time: Double) throws { pings += 1 }
    func send(_ frame: ParameterOutputFrame) throws {}
    func stop() { isConnected = false }
}

@MainActor
final class MonotonicReceiptTests: XCTestCase {
    private func peer(_ kind: OutputTransportKind,
                      flags: [String] = []) async throws -> (CodexProcessSupervisor, UInt16)
    {
        let name = kind == .osc ? "osc_peer.py" : "websocket_peer.py"
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/" + name)
        let process = CodexProcessSupervisor()
        let mode = kind == .osc ? [] : [kind == .rosbridge ? "rosbridge" : "websocket"]
        try await process.start(executablePath: "/usr/bin/python3", arguments: ["-u", fixture.path] + mode + flags)
        let line = try await process.readLine()
        return (process, try XCTUnwrap(line.flatMap(UInt16.init)))
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Loopback condition timed out")
    }

    private func adapter(_ kind: OutputTransportKind, wall: ReceiptWall,
                         capacity: Int = 64) -> any MonotonicOutputTransport
    {
        if kind == .osc { return OSCParameterAdapter(wallClock: { wall.read() }, receiveCapacity: capacity) }
        return WebSocketParameterAdapter(
            rosbridge: kind == .rosbridge,
            receiveCapacity: capacity,
            wallClock: { wall.read() }
        )
    }

    private func controller(_ adapter: any OutputTransport, kind: OutputTransportKind, port: UInt16,
                            wall: ReceiptWall) -> (OutputController, SurfaceSession)
    {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let configuration = SurfaceConfiguration(name: "receipt", parameters: [
            .init(id: "arm.j1", name: "Joint", minimum: -1, maximum: 1, defaultValue: 0.5),
            .init(id: "enable", name: "Enable", minimum: 0, maximum: 1, kind: .toggle)
        ])
        let session = SurfaceSession(hardwareDevice: ReceiptDevice(), configuration: configuration,
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        let controller = OutputController(session: session,
                                          store: JSONFileStore(fileURL: directory.appending(path: "settings.json")),
                                          adapter: adapter,
                                          automaticallyTicks: false, now: { wall.read() })
        var settings = controller.settings; settings.transport = kind; settings.port = Int(port)
        controller.apply(settings)
        return (controller, session)
    }

    private func count(_ adapter: any MonotonicOutputTransport, _ counts: ReceiptCounts) {
        let heartbeat = adapter.onPolicyHeartbeat, samples = adapter.onPolicySamples
        adapter.onPolicyHeartbeat = { time in counts.heartbeats += 1; counts.captured = time; heartbeat?(time) }
        adapter.onPolicySamples = { values in counts.samples += 1; samples?(values) }
    }

    func testProductionWebSocketAndROSBridgeStayReadyAcrossWallClockJumps() async throws {
        for kind in [OutputTransportKind.webSocket, .rosbridge] {
            let (process, port) = try await peer(kind)
            let wall = ReceiptWall(), source = adapter(kind, wall: wall), counts = ReceiptCounts()
            let (output, session) = controller(source, kind: kind, port: port, wall: wall)
            count(source, counts)
            output.start()
            try await wait { counts.heartbeats > 0 && counts.samples > 0 }
            output.tick(); session.setParameter("enable", to: 1); output.tick()
            XCTAssertEqual(output.status, .ready)
            for jump in [3600.0, -7200.0] {
                let previous = counts.heartbeats
                wall.jump(jump)
                try await Task.sleep(for: .milliseconds(110))
                output.tick()
                try await wait { counts.heartbeats > previous }
                output.tick()
                XCTAssertEqual(output.status, .ready)
                XCTAssertNil(output.error)
            }
            output.stop(); await process.stop()
        }
    }

    func testProductionOSCStaysReadyAcrossWallClockJumps() async throws {
        let (process, port) = try await peer(.osc)
        let wall = ReceiptWall(), source = adapter(.osc, wall: wall), counts = ReceiptCounts()
        let (output, session) = controller(source, kind: .osc, port: port, wall: wall)
        count(source, counts)
        output.start()
        try await wait { counts.heartbeats > 0 && counts.samples > 0 }
        output.tick(); session.setParameter("enable", to: 1); output.tick()
        XCTAssertEqual(output.status, .ready)
        for jump in [3600.0, -7200.0] {
            let previous = counts.heartbeats
            wall.jump(jump)
            try await Task.sleep(for: .milliseconds(110))
            output.tick()
            try await wait { counts.heartbeats > previous }
            output.tick()
            XCTAssertEqual(output.status, .ready)
            XCTAssertNil(output.error)
        }
        output.stop(); await process.stop()
    }

    func testRealIOReceiptRetainsItsAgeWhileMainActorIsBlocked() async throws {
        for kind in [OutputTransportKind.osc, .webSocket] {
            let (process, port) = try await peer(kind, flags: ["--receipt-marker", "--delay-reply"])
            let wall = ReceiptWall(), source = adapter(kind, wall: wall), counts = ReceiptCounts()
            let (output, _) = controller(source, kind: kind, port: port, wall: wall)
            count(source, counts)
            output.start()
            let marker = try await process.readLine()
            XCTAssertEqual(marker, "PING")
            stallReceiptConsumer(0.65)
            try await wait { counts.heartbeats > 0 }
            let captured = try XCTUnwrap(counts.captured)
            XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - captured, 0.3)
            output.tick()
            XCTAssertEqual(output.status, .heartbeatExpired)
            XCTAssertNotEqual(output.status, .ready)
            XCTAssertGreaterThan(output.droppedPackets, 0, "Queued stale actual must not be relabeled fresh")
            output.stop(); await process.stop()
        }
    }

    func testBoundedRealReceiveOverflowIsVisibleAndClosesWithoutAnOwnerStop() async throws {
        for kind in [OutputTransportKind.osc, .webSocket] {
            let (process, port) = try await peer(kind, flags: ["--receipt-marker", "--delay-reply", "--burst"])
            let wall = ReceiptWall(), source = adapter(kind, wall: wall, capacity: 4), counts = ReceiptCounts()
            source.onDroppedPacket = { counts.drops += 1 }
            source.onFailure = { counts.failure = $0 }
            try source.select(kind); try source.start(host: "127.0.0.1", port: port)
            try await wait { source.isConnected }
            try source.ping(atMonotonic: ProcessInfo.processInfo.systemUptime)
            let marker = try await process.readLine(); XCTAssertEqual(marker, "PING")
            stallReceiptConsumer(0.65)
            try await wait { counts.failure != nil }
            XCTAssertGreaterThan(counts.drops, 0)
            XCTAssertFalse(source.isConnected)
            source.stop(); await process.stop()
        }
    }

    func testDualCallbacksConsumeOnlyTheMonotonicProductionChannel() throws {
        let wall = ReceiptWall(), source = DualReceiptTransport()
        let (output, session) = controller(source, kind: .osc, port: 9000, wall: wall)
        output.start()
        let receipt = output.runtime.now
        source.onPolicyHeartbeat?(receipt)
        source.onPolicySamples?([.init(id: "arm.j1", value: 0, receivedAt: receipt)])
        source.onHeartbeat?(.distantFuture)
        source.onSamples?([.init(id: "arm.j1", value: 0.99, receivedAt: .distantFuture)])
        source.onPeerReset?(.distantPast)
        output.tick(); session.setParameter("enable", to: 1); output.tick()
        XCTAssertEqual(output.status, .ready)
        XCTAssertEqual(output.actual["arm.j1"], 0)
        XCTAssertGreaterThan(source.pings, 0)
        XCTAssertNil(output.error)
        output.stop()
    }
}
