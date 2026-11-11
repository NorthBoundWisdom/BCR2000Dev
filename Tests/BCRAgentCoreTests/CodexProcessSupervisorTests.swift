import Foundation
import XCTest
@testable import BCRAgentCore
@testable import BCRMCPAdapter
@testable import BCRSurfaceDomain
@testable import BCRCodexAdapter

@MainActor
final class CodexProcessSupervisorTests: XCTestCase {
    func testUnstartedReaderReturnsEOFAndWritesFail() async throws {
        let supervisor = CodexProcessSupervisor()
        let line = try await supervisor.readLine()
        XCTAssertNil(line)
        do {
            try await supervisor.sendLine("hello")
            XCTFail("Writing before launch must fail")
        } catch CodexProcessSupervisorError.alreadyStopped {}
        await supervisor.stop()
    }

    func testFailedLaunchClosesReaderAndAllowsRetry() async throws {
        let supervisor = CodexProcessSupervisor()
        do {
            try await supervisor.start(executablePath: "/nonexistent-bcr-test-\(UUID().uuidString)")
            XCTFail("Missing executable must fail")
        } catch CodexProcessSupervisorError.executableNotFound {}
        let line = try await supervisor.readLine()
        XCTAssertNil(line)
        try await supervisor.start(executablePath: "/bin/cat", arguments: [])
        let running = await supervisor.isRunning()
        XCTAssertTrue(running)
        await supervisor.stop()
        let stopped = await supervisor.isRunning()
        XCTAssertFalse(stopped)
    }

    func testRoundTripDuplicateStartStopAndRestart() async throws {
        let supervisor = CodexProcessSupervisor()
        try await supervisor.start(executablePath: "/bin/cat", arguments: [])
        do {
            try await supervisor.start(executablePath: "/bin/cat", arguments: [])
            XCTFail("Duplicate launch must fail")
        } catch CodexProcessSupervisorError.alreadyRunning {}
        let received = expectation(description: "stdio round trip")
        let reader = Task {
            let line = try await supervisor.readLine()
            XCTAssertEqual(line, "hello")
            received.fulfill()
        }
        try await supervisor.sendLine("hello")
        await fulfillment(of: [received], timeout: 3)
        await supervisor.stop()
        _ = try await reader.value
        await supervisor.stop()
        let eof = try await supervisor.readLine()
        XCTAssertNil(eof)
        try await supervisor.start(executablePath: "/bin/cat", arguments: [])
        let running = await supervisor.isRunning()
        XCTAssertTrue(running)
        await supervisor.stop()
    }

    func testStopReleasesPendingReader() async throws {
        let supervisor = CodexProcessSupervisor()
        try await supervisor.start(executablePath: "/bin/cat", arguments: [])
        let reader = Task { try await supervisor.readLine() }
        await supervisor.stop()
        let line = try await reader.value
        XCTAssertNil(line)
    }

    func testProtocolPayloadIsNotRedactedButDiagnosticsAre() async throws {
        let supervisor = CodexProcessSupervisor()
        try await supervisor.start(executablePath: "/bin/cat", arguments: [])
        let message = "API_KEY=fixture-value"
        try await supervisor.sendLine(message)
        let reply = try await supervisor.readLine()
        XCTAssertEqual(reply, message)
        // Read protocol data exactly; diagnostics must still mask credentials.
        try await supervisor.sendLine(message)
        try await Task.sleep(for: .milliseconds(50))
        let history = await supervisor.stdoutHistory()
        XCTAssertFalse(history.joined().contains("fixture-value"))
        await supervisor.stop()
    }

    func testSplitUTF8BytesAreReassembledBeforeDecoding() async throws {
        let supervisor = CodexProcessSupervisor()
        try await supervisor.start(
            executablePath: "/bin/sh",
            arguments: ["-c", #"printf '\344'; sleep 0.05; printf '\270\255\n'; read -r line"#]
        )
        let line = try await supervisor.readLine()
        XCTAssertEqual(line, "中")
        await supervisor.stop()
    }

    func testProtocolOverflowFailsVisiblyInsteadOfDroppingResponses() async throws {
        let supervisor = CodexProcessSupervisor(maxQueuedLines: 1)
        try await supervisor.start(executablePath: "/bin/sh", arguments: ["-c", "printf 'one\\ntwo\\n'; read -r line"])
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await supervisor.readLine()
            XCTFail("Overflow must fail visibly")
        } catch CodexProcessSupervisorError.launchFailed {}
        await supervisor.stop()
    }

    func testAbnormalExitRestartsOnlyUpToConfiguredLimit() async throws {
        let supervisor = CodexProcessSupervisor()
        let events = ExitEvents()
        await supervisor.setEventHandlers(onExit: { event in Task { await events.append(event) } })
        try await supervisor.start(executablePath: "/bin/sh", arguments: ["-c", "exit 7"],
                                   autoRestartLimit: 2, autoRestartInitialDelayMs: 5, autoRestartMaxDelayMs: 10)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await events.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let recorded = await events.values
        XCTAssertEqual(recorded.map(\.restartCount), [0, 1, 2])
        XCTAssertEqual(recorded.map(\.reason), Array(repeating: .crashed(code: 7), count: 3))
        await supervisor.stop()
    }

    func testFinalLineFromImmediatelyExitingProcessIsDelivered() async throws {
        let supervisor = CodexProcessSupervisor()
        try await supervisor.start(executablePath: "/bin/sh", arguments: ["-c", "printf 'final\\n'"])
        try await Task.sleep(for: .milliseconds(80))
        let line = try await supervisor.readLine()
        XCTAssertEqual(line, "final")
        await supervisor.stop()
    }

    func testNormalExitDoesNotRestart() async throws {
        let supervisor = CodexProcessSupervisor()
        let events = ExitEvents()
        await supervisor.setEventHandlers(onExit: { event in Task { await events.append(event) } })
        try await supervisor.start(executablePath: "/bin/sh", arguments: ["-c", "exit 0"], autoRestartLimit: 2)
        try await Task.sleep(for: .milliseconds(150))
        let recorded = await events.values
        XCTAssertEqual(recorded.map(\.reason), [.exited(code: 0)])
        await supervisor.stop()
    }

    func testStopKillsProcessThatIgnoresTermination() async throws {
        let supervisor = CodexProcessSupervisor()
        try await supervisor.start(config: .init(executablePath: "/bin/sh",
                                                 arguments: [
                                                     "-c",
                                                     "trap '' TERM INT; echo ready; while read -r line; do :; done"
                                                 ], stopTimeoutMs: 10))
        let ready = try await supervisor.readLine()
        XCTAssertEqual(ready, "ready")
        let began = ContinuousClock.now
        await supervisor.stop()
        XCTAssertLessThan(began.duration(to: .now), .seconds(2))
        let running = await supervisor.isRunning()
        XCTAssertFalse(running)
    }

    func testStoppingDuringBackoffPreventsRestart() async throws {
        let supervisor = CodexProcessSupervisor()
        let events = ExitEvents()
        await supervisor.setEventHandlers(onExit: { event in Task { await events.append(event) } })
        try await supervisor.start(executablePath: "/bin/sh", arguments: ["-c", "exit 7"],
                                   autoRestartLimit: 3, autoRestartInitialDelayMs: 200)
        try await Task.sleep(for: .milliseconds(80))
        await supervisor.stop()
        try await Task.sleep(for: .milliseconds(250))
        let count = await events.count
        XCTAssertEqual(count, 1)
    }
}

private actor ExitEvents {
    var values: [CodexProcessExitEvent] = []
    var count: Int { values.count }
    func append(_ event: CodexProcessExitEvent) { values.append(event) }
}
