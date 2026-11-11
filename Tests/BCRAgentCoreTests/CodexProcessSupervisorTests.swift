import Foundation
import XCTest
@testable import BCRAgentCore

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
}
