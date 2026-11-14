import BCRTestSupport
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRAgentCore
@testable import BCRCoreMIDIDriver

@MainActor
private final class PendingStartupMIDI: MIDIService {
    var connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var startup: CheckedContinuation<Void, any Error>?
    var synchronousStarts = 0
    var asynchronousStarts = 0
    var writes = 0
    func start() throws { synchronousStarts += 1 }
    func startWhenReady() async throws {
        asynchronousStarts += 1
        try await withCheckedThrowingContinuation { startup = $0 }
    }

    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws { writes += 1 }
}

private final class StartupSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    func mark() { lock.withLock { started = true } }
    var value: Bool { lock.withLock { started } }
}

@MainActor
final class MIDIInitializationTests: XCTestCase {
    func testPendingSystemStartupDoesNotHoldTheConsoleAndDoesNotRestartOnPortSelection() async throws {
        let device = PendingStartupMIDI()
        let model = ConsoleViewModel(stores: .temporary(), midiService: device,
                                     initialPreset: .robotArm, automaticallyAdvancesMock: false)
        XCTAssertTrue(model.startingMIDI)
        try await waitUntil { device.startup != nil }
        XCTAssertEqual(device.synchronousStarts, 0)
        XCTAssertEqual(device.asynchronousStarts, 1)
        model.setParameter("arm.j1", to: 42)
        model.applyEndpointSelection(.init())
        XCTAssertEqual(model.engine.value(of: "arm.j1"), 42)
        XCTAssertEqual(device.asynchronousStarts, 1)
        XCTAssertEqual(device.writes, 0)
        XCTAssertEqual(model.source, .mock)
        device.startup?.resume(); device.startup = nil
        try await waitUntil { !model.startingMIDI }
        XCTAssertFalse(model.startingMIDI)
    }

    func testAsyncStartupFailureIsVisibleAndLeavesMockUsable() async throws {
        let device = PendingStartupMIDI()
        let model = ConsoleViewModel(stores: .temporary(), midiService: device, automaticallyAdvancesMock: false)
        try await waitUntil { device.startup != nil }
        device.startup?.resume(throwing: MIDIStartupError.noReply); device.startup = nil
        try await waitUntil { !model.startingMIDI }
        XCTAssertFalse(model.startingMIDI)
        XCTAssertEqual(model.notice?.level, .error)
        XCTAssertEqual(model.source, .mock)
        XCTAssertFalse(model.connection.isConnected)
    }

    func testBlockingCoreMIDIInitializationRunsOutsideTheMainThread() async throws {
        let began = StartupSignal(), release = DispatchSemaphore(value: 0)
        let work = Task { @MainActor in
            try await CoreMIDIStartup.run(on: DispatchQueue(label: "test.slow-midi-init")) {
                XCTAssertFalse(Thread.isMainThread)
                began.mark()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        try await waitUntil("the blocking worker to start") { began.value }
        // The main actor reached here while the simulated blocking system call still waits.
        release.signal()
        try await work.value
    }
}
