import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

@MainActor
final class WebSocketParameterAdapterTests: XCTestCase {
    func testMalformedMessageClosesConnectionEvenWithoutOwnerStopCallback() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/websocket_peer.py")
        let process = CodexProcessSupervisor()
        try await process.start(
            executablePath: "/usr/bin/python3",
            arguments: ["-u", fixture.path, "websocket", "--malformed"]
        )
        let portLine = try await process.readLine()
        let port = try XCTUnwrap(portLine.flatMap(UInt16.init))
        let adapter = WebSocketParameterAdapter()
        var failure: String?
        adapter.onFailure = { failure = $0 } // Deliberately does not call stop().
        try adapter.start(host: "127.0.0.1", port: port)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !adapter.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try adapter.ping(at: Date())
        while failure == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(failure)
        while await process.isRunning(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let peerRunning = await process.isRunning()
        XCTAssertFalse(peerRunning, "A failed adapter must close the peer socket itself")
        XCTAssertFalse(adapter.isConnected)
        adapter.stop()
        await process.stop()
    }

    func testQueueOverflowAndSendFailureTearDownWithoutOwnerIntervention() async throws {
        for overflow in [true, false] {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "Fixtures/websocket_peer.py")
            let process = CodexProcessSupervisor()
            try await process.start(executablePath: "/usr/bin/python3", arguments: ["-u", fixture.path, "websocket"])
            let line = try await process.readLine()
            let port = try XCTUnwrap(line.flatMap(UInt16.init))
            let adapter = WebSocketParameterAdapter(queueLimit: overflow ? 1 : 64, writeMessage: { socket, text in
                if !overflow, text.contains("command") { throw MotionSafetyError("injected write failure") }
                try await socket.send(.string(text))
            })
            var heartbeat = false, failures = 0
            adapter.onHeartbeat = { _ in heartbeat = true }
            adapter.onFailure = { _ in failures += 1 }
            try adapter.start(host: "127.0.0.1", port: port)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !adapter.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try adapter.ping(at: Date())
            while !heartbeat, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(heartbeat)
            try adapter.send(.init(enabled: true, values: ["arm.j1": 20]))
            if overflow { XCTAssertThrowsError(try adapter.send(.init(enabled: true, values: ["arm.j1": 30]))) }
            while failures == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(failures, 1)
            XCTAssertFalse(adapter.isConnected)
            while await process.isRunning(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let running = await process.isRunning()
            XCTAssertFalse(running)
            adapter.stop()
            await process.stop()
        }
    }

    func testPeerEpochChangeNotifiesSafetyOwner() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/websocket_peer.py")
        let process = CodexProcessSupervisor()
        try await process.start(
            executablePath: "/usr/bin/python3",
            arguments: ["-u", fixture.path, "websocket", "--restart"]
        )
        let line = try await process.readLine()
        let port = try XCTUnwrap(line.flatMap(UInt16.init))
        let adapter = WebSocketParameterAdapter()
        var heartbeats = 0, resets = 0
        adapter.onHeartbeat = { _ in heartbeats += 1 }
        adapter.onPeerReset = { _ in resets += 1 }
        try adapter.start(host: "127.0.0.1", port: port)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !adapter.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        for expected in 1 ... 2 {
            try adapter.ping(at: Date())
            while heartbeats < expected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertEqual(heartbeats, 2)
        XCTAssertEqual(resets, 1)
        adapter.stop()
        await process.stop()
    }

    func testWebSocketAndROSBridgeHeartbeatStateCommandsAndStop() async throws {
        for rosbridge in [false, true] {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "Fixtures/websocket_peer.py")
            let process = CodexProcessSupervisor()
            try await process.start(
                executablePath: "/usr/bin/python3",
                arguments: ["-u", fixture.path, rosbridge ? "rosbridge" : "websocket"]
            )
            let portLine = try await process.readLine()
            let port = try XCTUnwrap(portLine.flatMap(UInt16.init))
            let adapter = WebSocketParameterAdapter(rosbridge: rosbridge)
            var heartbeat = false
            var samples: [ParameterSample] = []
            var failure: String?
            adapter.onHeartbeat = { _ in heartbeat = true }
            adapter.onSamples = { samples = $0 }
            adapter.onFailure = { failure = $0 }
            try adapter.start(host: "127.0.0.1", port: port)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !adapter.isConnected, failure == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertNil(failure)
            XCTAssertTrue(adapter.isConnected)
            try adapter.ping(at: Date())
            while (!heartbeat || samples.isEmpty), failure == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(heartbeat)
            XCTAssertEqual(samples.first?.id, "arm.j1")
            try adapter.send(.init(enabled: true, values: ["arm.j1": 30]))
            let commandLine = try await process.readLine()
            let command = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(commandLine).utf8))
            XCTAssertEqual(command.objectValue?["values"]?.objectValue?["arm.j1"]?.finiteNumber, 30)
            adapter.stop()
            let stopLine = try await process.readLine()
            let stop = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(stopLine).utf8))
            XCTAssertEqual(stop.objectValue?["enabled"], .bool(false))
            XCTAssertEqual(stop.objectValue?["values"], .object([:]))
            await process.stop()
        }
    }
}
