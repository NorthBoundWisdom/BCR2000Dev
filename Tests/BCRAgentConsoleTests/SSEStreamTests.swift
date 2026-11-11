import Foundation
import Network
import XCTest
@testable import BCRAgentCore
@testable import BCRAgentConsole

@MainActor
private final class SSEDevice: SurfaceDevice {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func send(_ message: MIDIVoiceMessage) throws {}
}

@MainActor
private final class SSEProbe {
    let connection: NWConnection
    var closed = false
    init(port: UInt16, session: String? = nil) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let sessionHeader = session.map { "Mcp-Session-Id: \($0)\r\n" } ?? ""
        let version = session == nil ? MCPVersions.current : MCPVersions.legacy
        let request = Data("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer fixture\r\nAccept: text/event-stream\r\nMCP-Protocol-Version: \(version)\r\n\(sessionHeader)\r\n"
            .utf8)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .ready = state {
                    self.connection.send(content: request, completion: .contentProcessed { _ in })
                    self.read()
                } else if case .failed = state { self.closed = true }
            }
        }
        connection.start(queue: .main)
    }

    deinit { connection.cancel() }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if complete || error != nil { self.closed = true }
                else { self.read() }
            }
        }
    }
}

@MainActor
final class SSEStreamTests: XCTestCase {
    private func session(configuration: SurfaceConfiguration = .robotArmDemo()) -> SurfaceSession {
        SurfaceSession(
            hardwareDevice: SSEDevice(),
            configuration: configuration,
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        if !condition() { XCTFail("Timed out waiting for SSE state"); throw CancellationError() }
    }

    func testBurstCoalescesIntoOneLatestValueEvent() async throws {
        let source = session()
        var writes: [Data] = []
        let server = MCPHTTPServer(
            router: MCPRouter(service: AgentControlService(session: source)),
            eventWriter: { _, data, completion in writes.append(data); completion(nil) }
        )
        let port = try await server.start(port: 0, token: "fixture")
        defer { server.stop() }
        let probe = SSEProbe(port: port)
        try await until { server.activeStreamCount == 1 }
        for value in 1 ... 100 { source.setParameter("arm.j1", to: Double(value)) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(writes.count, 2) // Initial full snapshot plus one coalesced update.
        let payload = try XCTUnwrap(String(data: try XCTUnwrap(writes.last), encoding: .utf8)?.split(separator: "\n")
            .first(where: { $0.hasPrefix("data: ") }))
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(payload.dropFirst(6).utf8))
        XCTAssertEqual(value.objectValue?["params"]?.objectValue?["values"]?.objectValue?["arm.j1"]?.finiteNumber, 100)
        XCTAssertFalse(probe.closed)
    }

    func testSnapshotLargerThanDeltaQuotaCanSubscribe() async throws {
        let parameters = (0 ..< 1000).map { ParameterDefinition(
            id: ParameterID("p\($0)" + String(repeating: "x", count: 100)),
            name: "P\($0)"
        ) }
        let source = session(configuration: .init(name: "Large", parameters: parameters))
        var sizes: [Int] = []
        let server = MCPHTTPServer(
            router: MCPRouter(service: AgentControlService(session: source)),
            eventWriter: { _, data, completion in sizes.append(data.count); completion(nil) }
        )
        let port = try await server.start(port: 0, token: "fixture")
        defer { server.stop() }
        let probe = SSEProbe(port: port)
        try await until { server.activeStreamCount == 1 }
        XCTAssertGreaterThan(try XCTUnwrap(sizes.first), 65_536)
        XCTAssertFalse(probe.closed)
        XCTAssertFalse(server.router.service.audit.contains { $0.method == "sse" && !$0.succeeded })
    }

    func testBackpressureActuallyClosesTheClientConnection() async throws {
        let parameters = (0 ..< 50).map { ParameterDefinition(
            id: ParameterID("p\($0)" + String(repeating: "x", count: 500)),
            name: "P\($0)"
        ) }
        let source = session(configuration: .init(name: "Slow", parameters: parameters))
        let server = MCPHTTPServer(
            router: MCPRouter(service: AgentControlService(session: source)),
            eventWriter: { _, _, _ in /* Simulate a send which never completes. */ }
        )
        let port = try await server.start(port: 0, token: "fixture")
        defer { server.stop() }
        let probe = SSEProbe(port: port)
        try await until { server.activeStreamCount == 1 }
        for value in 1 ... 5 {
            for parameter in parameters { source.setParameter(parameter.id, to: Double(value)) }
            try await Task.sleep(for: .milliseconds(30))
        }
        try await until { probe.closed }
        XCTAssertEqual(server.activeStreamCount, 0)
        XCTAssertTrue(server.router.service.audit.contains { $0.method == "sse" && !$0.succeeded })
    }

    func testObserverIsRemovedWhenServerIsReleased() async throws {
        let source = session()
        let router = MCPRouter(service: AgentControlService(session: source))
        var server: MCPHTTPServer? = MCPHTTPServer(router: router)
        XCTAssertNotNil(server)
        XCTAssertEqual(source.parameterObserverCount, 1)
        server = nil
        try await until { source.parameterObserverCount == 0 }
    }

    func testDeletingLegacySessionClosesItsEventStream() async throws {
        let server = MCPHTTPServer(router: MCPRouter(service: AgentControlService(session: session())))
        let port = try await server.start(port: 0, token: "fixture")
        defer { server.stop() }
        func request(
            _ method: String,
            sessionID: String? = nil,
            notification: Bool = false,
            delete: Bool = false
        ) async throws -> HTTPURLResponse {
            var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
            if !notification { object["id"] = .number(1) }
            if method == "initialize" { object["params"] = .object([
                "protocolVersion": .string(MCPVersions.legacy),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("fixture"), "version": .string("1")])
            ]) }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = delete ? "DELETE" : "POST"
            request.timeoutInterval = 3
            if !delete { request.httpBody = try JSONEncoder().encode(JSONValue.object(object)) }
            request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(MCPVersions.legacy, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
            let client = URLSession(configuration: config)
            defer { client.invalidateAndCancel() }
            let (_, response) = try await client.data(for: request)
            return try XCTUnwrap(response as? HTTPURLResponse)
        }
        let initialized = try await request("initialize")
        let id = try XCTUnwrap(initialized.value(forHTTPHeaderField: "Mcp-Session-Id"))
        _ = try await request("notifications/initialized", sessionID: id, notification: true)
        let probe = SSEProbe(port: port, session: id)
        try await until { server.activeStreamCount == 1 }
        let deleted = try await request("", sessionID: id, delete: true)
        XCTAssertEqual(deleted.statusCode, 200)
        try await until { probe.closed }
        XCTAssertEqual(server.activeStreamCount, 0)
    }

    func testSnapshotAndDeltaBudgetsAreIndependent() throws {
        var buffer = SSEOutboundBuffer()
        try buffer.enqueue(Data(repeating: 0, count: 100_000), snapshot: true)
        try buffer.enqueue(Data(repeating: 0, count: 65_536), snapshot: false)
        XCTAssertThrowsError(try buffer.enqueue(Data([1]), snapshot: false))
        XCTAssertEqual(buffer.next()?.count, 100_000)
        buffer.complete()
        XCTAssertEqual(buffer.next()?.count, 65_536)
        buffer.complete()
        XCTAssertEqual(buffer.deltaBytes, 0)
        XCTAssertEqual(buffer.snapshotBytes, 0)
    }
}
