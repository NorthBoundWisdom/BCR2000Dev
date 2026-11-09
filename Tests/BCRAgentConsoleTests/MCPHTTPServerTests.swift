import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class HTTPFakeDevice: SurfaceDevice {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func send(_ message: MIDIVoiceMessage) throws {}
}

@MainActor
private final class HTTPFakeCredentials: MCPCredentialStore {
    var calls = 0
    func loadOrCreate() async throws -> String { calls += 1; return "isolated-test-credential" }
}

@MainActor
private final class SuspendedMCPCredentials: MCPCredentialStore {
    let started = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<String, any Error>?

    func loadOrCreate() async throws -> String {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.continuation.yield(())
        }
    }
}

@MainActor
final class MCPHTTPServerTests: XCTestCase {
    private let credential = "isolated-test-credential"

    private func makeServer() -> MCPHTTPServer {
        let session = SurfaceSession(hardwareDevice: HTTPFakeDevice(), saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        return MCPHTTPServer(router: MCPRouter(service: AgentControlService(session: session)))
    }

    private func request(port: UInt16, method: String = "ping", params: [String: JSONValue] = [:],
                         token: String? = nil, headers overrides: [String: String] = [:],
                         legacySession: String? = nil, notification: Bool = false,
                         httpMethod: String = "POST") async throws -> (Data, HTTPURLResponse) {
        var parameters = params
        if legacySession == nil, method != "initialize" {
            parameters["_meta"] = .object([
                "io.modelcontextprotocol/protocolVersion": .string(MCPVersions.current),
                "io.modelcontextprotocol/clientCapabilities": .object([:]),
            ])
        }
        var body: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(parameters)]
        if !notification { body["id"] = .number(1) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = httpMethod
        request.timeoutInterval = 2
        if httpMethod == "POST" { request.httpBody = try JSONEncoder().encode(JSONValue.object(body)) }
        request.setValue("Bearer \(token ?? credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(legacySession == nil ? MCPVersions.current : MCPVersions.legacy, forHTTPHeaderField: "MCP-Protocol-Version")
        if let legacySession { request.setValue(legacySession, forHTTPHeaderField: "Mcp-Session-Id") }
        else {
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
            if let name = parameters["name"]?.stringValue { request.setValue(name, forHTTPHeaderField: "Mcp-Name") }
        }
        for (key, value) in overrides { request.setValue(value, forHTTPHeaderField: key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let (data, response) = try await client.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    func testLoopbackModernDiscoveryWriteReadAndSourceAttribution() async throws {
        let server = makeServer()
        let port = try await server.start(port: 0, token: credential)
        defer { server.stop() }
        let (discovery, response) = try await request(port: port, method: "server/discover")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertNotNil(try JSONDecoder().decode(JSONValue.self, from: discovery).objectValue?["result"])
        let (_, writeResponse) = try await request(port: port, method: "tools/call", params: [
            "name": .string("set_parameter"), "arguments": .object(["id": .string("arm.j1"), "value": .number(90)]),
        ])
        XCTAssertEqual(writeResponse.statusCode, 200)
        XCTAssertEqual(server.router.service.session.engine.value(of: "arm.j1"), 90)
        XCTAssertEqual(server.router.service.session.mock.value(of: .pushEncoder(group: 1, 1)), 95)
        XCTAssertEqual(server.router.service.session.events.last?.origin, .agent)
        let (_, readResponse) = try await request(port: port, method: "tools/call", params: [
            "name": .string("get_parameter"), "arguments": .object(["id": .string("arm.j1")]),
        ])
        XCTAssertEqual(readResponse.statusCode, 200)
        XCTAssertEqual(server.router.sessionCount, 0)
    }

    func testAuthenticationOriginHostAndModernHeaderValidation() async throws {
        let server = makeServer()
        let port = try await server.start(port: 0, token: credential)
        defer { server.stop() }
        let (_, wrongToken) = try await request(port: port, token: "incorrect")
        XCTAssertEqual(wrongToken.statusCode, 401)
        XCTAssertEqual(wrongToken.value(forHTTPHeaderField: "WWW-Authenticate"), "Bearer")
        let (_, missingToken) = try await request(port: port, headers: ["Authorization": ""])
        XCTAssertEqual(missingToken.statusCode, 401)
        for origin in ["null", "https://evil.example", "http://127.0.0.1:1", "http://localhost.evil.example"] {
            let (_, response) = try await request(port: port, headers: ["Origin": origin])
            XCTAssertEqual(response.statusCode, 403)
        }
        let (_, localOrigin) = try await request(port: port, headers: ["Origin": "http://localhost:\(port)"])
        XCTAssertEqual(localOrigin.statusCode, 200)
        let (_, wrongHost) = try await request(port: port, headers: ["Host": "evil.example"])
        XCTAssertEqual(wrongHost.statusCode, 403)
        let (_, mismatch) = try await request(port: port, headers: ["Mcp-Method": "tools/list"])
        XCTAssertEqual(mismatch.statusCode, 400)
        let (_, unsupportedContent) = try await request(port: port, headers: ["Content-Type": "text/plain"])
        XCTAssertEqual(unsupportedContent.statusCode, 415)
        let (_, unsupportedAccept) = try await request(port: port, headers: ["Accept": "text/plain"])
        XCTAssertEqual(unsupportedAccept.statusCode, 406)
        XCTAssertTrue(server.router.service.audit.allSatisfy { !$0.detail.contains(credential) })
    }

    func testLegacySessionHeaderNotificationAndDeletion() async throws {
        let server = makeServer()
        let port = try await server.start(port: 0, token: credential)
        defer { server.stop() }
        let (_, initResponse) = try await request(port: port, method: "initialize", params: [
            "protocolVersion": .string(MCPVersions.legacy), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("neutral-client"), "version": .string("1")]),
        ], headers: ["MCP-Protocol-Version": MCPVersions.legacy])
        XCTAssertEqual(initResponse.statusCode, 200)
        let session = try XCTUnwrap(initResponse.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let (_, notification) = try await request(port: port, method: "notifications/initialized", legacySession: session, notification: true)
        XCTAssertEqual(notification.statusCode, 202)
        let (_, tools) = try await request(port: port, method: "tools/list", legacySession: session)
        XCTAssertEqual(tools.statusCode, 200)
        XCTAssertEqual(server.router.sessionCount, 1)
        let (_, deleted) = try await request(port: port, legacySession: session, httpMethod: "DELETE")
        XCTAssertEqual(deleted.statusCode, 200)
        let (_, unknownSession) = try await request(port: port, method: "tools/list", legacySession: session)
        XCTAssertEqual(unknownSession.statusCode, 404)
    }

    func testOccupiedPortFailsVisiblyAndStopClosesListener() async throws {
        let first = makeServer(), second = makeServer()
        let port = try await first.start(port: 0, token: credential)
        defer { first.stop(); second.stop() }
        do {
            _ = try await second.start(port: port, token: credential)
            XCTFail("Occupied fixed port must not silently choose another port")
        } catch {
            guard case .failed = second.state else { return XCTFail("Listener failure must remain visible") }
        }
        first.stop()
        XCTAssertEqual(first.state, .stopped)
        XCTAssertEqual(first.router.sessionCount, 0)
        do {
            _ = try await request(port: port)
            XCTFail("Stopped service should not accept requests")
        } catch {}
    }

    func testPendingKeychainReadLeavesMainActorResponsiveAndStopPreventsLateStartup() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = SuspendedMCPCredentials()
        let controller = MCPController(session: makeServer().router.service.session,
            store: JSONFileStore(fileURL: directory.appending(path: "settings.json")), credentials: credentials)
        let start = Task { @MainActor in await controller.setEnabled(true) }
        var events = credentials.started.stream.makeAsyncIterator()
        _ = await events.next()
        XCTAssertTrue(controller.isStarting)
        XCTAssertEqual(controller.server.state, .stopped)
        controller.stop()
        credentials.continuation?.resume(returning: credential)
        await start.value
        XCTAssertFalse(controller.settings.enabled)
        XCTAssertFalse(controller.isStarting)
        XCTAssertEqual(controller.server.state, .stopped)
        XCTAssertNil(controller.error)
    }

    func testV1ConfigurationMigrationIsVisibleAndDoesNotOverwriteSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(
            hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
            configuration: JSONFileStore(fileURL: directory.appending(path: "configuration.json"))
        )
        var original = try JSONValue.encoded(SurfaceConfiguration.robotArmDemo()).objectValue!
        original["version"] = .number(1)
        if case let .array(parameters) = original["parameters"] {
            original["parameters"] = .array(parameters.map {
                var object = $0.objectValue!
                object.removeValue(forKey: "agentWritable")
                return .object(object)
            })
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(JSONValue.object(original))
        try data.write(to: stores.configuration.fileURL)
        let model = ConsoleViewModel(stores: stores, startsMIDI: false)
        XCTAssertEqual(model.configuration.version, 2)
        XCTAssertFalse(model.configuration.parameter("arm.enabled")!.agentWritable)
        XCTAssertTrue(model.notice?.text.contains("迁移") == true)
        XCTAssertEqual(try Data(contentsOf: stores.configuration.fileURL), data)
    }

    func testParserRejectsSmugglingAndWaitsForCompleteBody() throws {
        let prefix = Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n".utf8)
        XCTAssertNil(try MCPHTTPParser.parse(prefix + Data("{".utf8)))
        XCTAssertEqual(try MCPHTTPParser.parse(prefix + Data("{}".utf8))?.body, Data("{}".utf8))
        for raw in [
            "POST /mcp HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nContent-Length: 0\r\n\r\nextra",
            "POST /mcp HTTP/1.1\r\n\r\n",
        ] { XCTAssertThrowsError(try MCPHTTPParser.parse(Data(raw.utf8))) }
        XCTAssertThrowsError(try MCPHTTPParser.parse(Data(repeating: 65, count: 16_385)))
    }

    func testSettingsDefaultOffAndCredentialIsNotTouchedForReadOnlyConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = HTTPFakeCredentials()
        let service = makeServer().router.service
        let controller = MCPController(session: service.session,
            store: JSONFileStore(fileURL: directory.appending(path: "settings.json")), credentials: credentials)
        XCTAssertFalse(controller.settings.enabled)
        XCTAssertEqual(credentials.calls, 0)
        var draft = controller.settings
        draft.permissions.parameterWrite = false
        await controller.apply(draft)
        XCTAssertFalse(controller.service.permissions.parameterWrite)
        XCTAssertEqual(credentials.calls, 0)
        draft.port = 0
        await controller.apply(draft)
        XCTAssertNotNil(controller.error)
        XCTAssertNotEqual(controller.settings.port, 0)
    }
}
