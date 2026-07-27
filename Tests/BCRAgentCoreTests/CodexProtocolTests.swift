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

    func testModelListPageParsing() throws {
        let page = try CodexModelListPage(
            from: .object([
                "models": .array([
                    .object([
                        "id": .string("model-a"),
                        "displayName": .string("Model A"),
                        "isDefault": .bool(true),
                        "defaultReasoningEffort": .string("medium"),
                        "supportedReasoningEfforts": .array([.string("low"), .string("medium")]),
                        "hidden": .bool(false)
                    ]),
                    .object([
                        "id": .string("model-b"),
                        "displayName": .string("Hidden"),
                        "isDefault": .bool(false),
                        "hidden": .bool(true)
                    ])
                ]),
                "nextCursor": .string("cursor-2")
            ])
        )

        XCTAssertEqual(page.nextCursor, "cursor-2")
        XCTAssertEqual(page.models.count, 2)
        XCTAssertEqual(page.models.first?.id, "model-a")
    }

    func testServerEventParsing() throws {
        let startedEnvelope = CodexEnvelope(
            id: .string("1"),
            method: CodexMethod.turnStarted.rawValue,
            params: .object([
                "threadId": .string("t1"),
                "turnId": .string("u1")
            ])
        )
        let parsed = try XCTUnwrap(try startedEnvelope.asServerEvent())
        guard case let .turnStarted(threadID, turnID) = parsed else {
            return XCTFail("expect turnStarted")
        }
        XCTAssertEqual(threadID, "t1")
        XCTAssertEqual(turnID, "u1")
    }

    func testSanitizeSensitiveLog() {
        let input = "AUTHORIZATION=token-abc123 API_KEY=super-secret"
        let scrubbed = CodexLogSanitizer.sanitize(input)
        XCTAssertNotEqual(input, scrubbed)
        XCTAssertFalse(scrubbed.contains("token-abc123"))
        XCTAssertFalse(scrubbed.contains("super-secret"))
    }
}
