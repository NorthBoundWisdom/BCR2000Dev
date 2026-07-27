import Foundation
import XCTest
@testable import BCRAgentCore

final class CodexProtocolTests: XCTestCase {
    func testJSONValueAndEnvelopeRoundTrip() throws {
        let envelope = CodexEnvelope(
            id: .number(7),
            method: "model/list",
            params: .object([
                "cursor": .string("cursor-1"),
                "limit": .number(20),
            ]),
            result: .object(["ok": .bool(true)])
        )

        let encoded = try envelope.encodeJSON()
        let decoded = try CodexEnvelope.decodeJSON(encoded)

        XCTAssertEqual(decoded.id, .number(7))
        XCTAssertEqual(decoded.method, "model/list")
        XCTAssertEqual(decoded.params, envelope.params)
        XCTAssertEqual(decoded.result, envelope.result)
    }

    func testTransportMatchesRequestAndResponseWithTimeout() async throws {
        let transport = InMemoryJSONLTransport()
        let client = CodexRPCClient(transport: transport, defaultTimeout: .seconds(2))
        await client.start()

        let requestTask = Task {
            try await client.sendRequest(
                .accountRead,
                params: .object(["verbose": .bool(true)]),
                timeout: .seconds(1)
            )
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        var sentLines = await transport.consumeSentLines()
        while sentLines.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
            sentLines = await transport.consumeSentLines()
        }
        let request = try CodexEnvelope.decodeJSON(sentLines[0])
        let response = try CodexEnvelope(
            id: request.id,
            result: .object([
                "account": .string("demo")
            ])
        ).encodeJSON()
        await transport.enqueueIncoming(response)

        let reply = try await requestTask.value
        if case let .object(payload) = reply.result {
            XCTAssertEqual(payload["account"], .string("demo"))
        } else {
            XCTFail("reply.result 应返回 object payload")
        }
        await client.stop()
    }

    func testRequestTimeoutReportsError() async {
        let transport = InMemoryJSONLTransport()
        let client = CodexRPCClient(transport: transport, defaultTimeout: .milliseconds(50))
        await client.start()

        do {
            _ = try await client.sendRequest(.modelList, timeout: .milliseconds(20))
            XCTFail("应超时")
        } catch {
            XCTAssertTrue(error is CodexRPCError)
        }

        await client.stop()
    }
}
