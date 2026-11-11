import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
final class WebSocketParameterAdapterTests: XCTestCase {
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
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
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
