import BCRTestSupport
import Foundation
import XCTest
@testable import BCRAgentCore
@testable import BCRMCPAdapter
@testable import BCRSurfaceDomain
@testable import BCRCodexAdapter

@MainActor
final class CodexProcessIntegrationTests: XCTestCase {
    private func connection(mode: String) async throws -> CodexRPCClient {
        let process = CodexProcessSupervisor()
        let script = #"""
        import sys, json
        mode = sys.argv[1]
        held = None
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            if mode == 'eof': sys.exit(3)
            if mode == 'malformed':
                print('{broken', flush=True)
                continue
            reply = {'id': request['id'], 'result': request.get('params') or {'ok': True}}
            if mode == 'error':
                reply = {'id': request['id'], 'error': {'code': -32000, 'message': 'fixture rejection'}}
            if mode == 'reverse':
                if held is None:
                    held = reply
                    continue
                print(json.dumps(reply), flush=True)
                print(json.dumps(held), flush=True)
                held = None
            else:
                print(json.dumps(reply), flush=True)
                if mode == 'duplicate': print(json.dumps(reply), flush=True)
        """#
        try await process.start(executablePath: "/usr/bin/python3", arguments: ["-u", "-c", script, mode])
        let client = CodexRPCClient(transport: process, defaultTimeout: .seconds(2))
        await client.start()
        return client
    }

    func testRealProcessMatchesOutOfOrderResponses() async throws {
        let client = try await connection(mode: "reverse")
        async let first = client.sendRequest(.accountRead, params: .object(["sequence": .number(1)]))
        async let second = client.sendRequest(.modelList, params: .object(["sequence": .number(2)]))
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.result, .object(["sequence": .number(1)]))
        XCTAssertEqual(b.result, .object(["sequence": .number(2)]))
        await client.stop()
    }

    func testErrorResponseDoesNotBreakFollowingRequests() async throws {
        let client = try await connection(mode: "error")
        for _ in 0 ..< 2 {
            do {
                _ = try await client.sendRequest(.accountRead)
                XCTFail("Expected explicit server rejection")
            } catch CodexRPCError.requestRejected(let code, let message) {
                XCTAssertEqual(code, -32000)
                XCTAssertEqual(message, "fixture rejection")
            }
        }
        await client.stop()
    }

    func testMalformedJSONFailsPendingRequest() async throws {
        let client = try await connection(mode: "malformed")
        do {
            _ = try await client.sendRequest(.accountRead)
            XCTFail("Malformed JSON must fail")
        } catch CodexRPCError.invalidMessage {}
        await client.stop()
    }

    func testEarlyExitFailsPendingRequest() async throws {
        let client = try await connection(mode: "eof")
        do {
            _ = try await client.sendRequest(.accountRead)
            XCTFail("EOF must fail")
        } catch CodexRPCError.disconnected {}
        await client.stop()
    }

    func testDuplicateResponseFailsConnectionRatherThanReusingIt() async throws {
        let client = try await connection(mode: "duplicate")
        let disconnects = SendableCounter()
        await client.setDisconnectHandler { _ in disconnects.increment() }
        _ = try await client.sendRequest(.accountRead)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while disconnects.value == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        do {
            _ = try await client.sendRequest(.modelList)
            XCTFail("A duplicate response must close the connection")
        } catch CodexRPCError.disconnected {}
        await client.stop()
    }

    func testStopAllReleasesConcurrentPendingRequests() async throws {
        let client = try await connection(mode: "reverse")
        let pending = Task {
            do {
                _ = try await client.sendRequest(.accountRead)
                XCTFail("Stopping must cancel pending requests")
            } catch CodexRPCError.disconnected {}
        }
        try await Task.sleep(for: .milliseconds(30))
        await client.stop()
        try await pending.value
    }
}
