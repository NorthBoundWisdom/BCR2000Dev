@testable import BCRFoundation
@testable import BCRCodexAdapter
@testable import BCRSurfaceDomain
@testable import BCRExamples
@testable import BCRConfigurationAdapter
@testable import BCRMCPAdapter
@testable import BCRHTTPTransport
@testable import BCRCoreMIDIDriver
@testable import BCRPersistenceAdapter
import BCRTestSupport
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class PendingStartupMIDI: MIDIService {
    var connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var startup: CheckedContinuation<Void, any Error>?
    var synchronousStarts = 0
    var asynchronousStarts = 0
    var begunStartups = 0
    var writes = 0
    func start() throws { synchronousStarts += 1 }
    func beginStartup() { begunStartups += 1 }
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
                                     initialPreset: .robotArm, automaticallyAdvancesMock: false, timing: .immediate)
        XCTAssertTrue(model.startingMIDI)
        // Begun synchronously during init, before the window's first layout frees the main actor.
        XCTAssertEqual(device.begunStartups, 1)
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
        let model = ConsoleViewModel(
            stores: .temporary(),
            midiService: device,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
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

    func testCoreMIDIStartupIsDispatchedBeforeTheCallerYields() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let pending = CoreMIDIStartup.begin(on: DispatchQueue(label: "test.eager-midi-init")) {
            started.signal()
            _ = release.wait(timeout: .now() + 2)
        }
        // Still inside this main-actor job: the queue work runs although nothing has awaited yet.
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        release.signal()
        try await pending.value()
    }

    func testCoreMIDIStartupFailureReachesALateAwaiter() async throws {
        let finished = DispatchSemaphore(value: 0)
        let pending = CoreMIDIStartup.begin(on: DispatchQueue(label: "test.failed-midi-init")) {
            defer { finished.signal() }
            throw MIDIStartupError.noReply
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        do { try await pending.value(); XCTFail("Expected the startup failure") }
        catch {
            guard case .noReply? = error as? MIDIStartupError else { return XCTFail("Unexpected \(error)") }
        }
    }
}
