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
import XCTest
@testable import BCRAgentConsole

@MainActor
final class ConsoleTimingTests: XCTestCase {
    func testProductionTimingDefaultsPreserveCalibratedDurations() {
        XCTAssertEqual(ConsoleTiming.frame, .milliseconds(16))
        XCTAssertEqual(ConsoleTiming.activity, .milliseconds(120))
        XCTAssertEqual(ConsoleTiming.connection, .milliseconds(300))
        XCTAssertEqual(ConsoleTiming.notice, .seconds(ConsoleViewModel.infoNoticeSeconds))
        XCTAssertEqual(ConsoleViewModel.infoNoticeSeconds, 6)
        XCTAssertEqual(ConsoleTiming.minimumPressSeconds, 0.08)
        XCTAssertEqual(ConsoleTiming.pulse, .milliseconds(180))
        XCTAssertEqual(ConsoleTiming.blink, .milliseconds(50))
        XCTAssertEqual(ConsoleTiming.outputTick, .milliseconds(20))
        XCTAssertEqual(ConsoleTiming.webSocketPoll, .milliseconds(200))
        XCTAssertEqual(BCRDisplayModel.Calibration.valueHoldSeconds, 0.8)
        XCTAssertEqual(BCRDisplayModel.Calibration.buttonHoldSeconds, 0.5)
        let defaults = ConsoleTiming()
        XCTAssertEqual(defaults.intentNow().timeIntervalSinceNow, 0, accuracy: 0.01)
        XCTAssertEqual(defaults.work.now(), ProcessInfo.processInfo.systemUptime, accuracy: 0.01)
        XCTAssertEqual(defaults.presentation.now(), ProcessInfo.processInfo.systemUptime, accuracy: 0.01)
    }

    func testManualSleeperPreservesDeadlineAndCancellation() async throws {
        let clock = ManualHostTime()
        var completed = false
        let task = Task { try await clock.time.sleep(.milliseconds(300)); completed = true }
        try await waitUntil { clock.pendingCount == 1 }
        clock.advance(by: 0.299)
        XCTAssertFalse(completed)
        clock.advance(by: 0.001)
        try await task.value
        XCTAssertTrue(completed)
        let cancelled = Task { try await clock.time.sleep(.seconds(6)) }
        try await waitUntil { clock.pendingCount == 1 }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancellation must throw") } catch is CancellationError {}
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testConnectionOfferWaitsForTheFullStablePeriod() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stores = ConsoleStores(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
                                   configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
        try stores.hardwareMap.save(.mockPreset())
        let clock = ManualHostTime()
        let midi = RecordingMIDIService(notifyOnStart: true)
        let model = ConsoleViewModel(stores: stores, midiService: midi,
                                     automaticallyAdvancesMock: false,
                                     timing: .init(work: clock.time, presentation: clock.time))
        try await waitUntil { clock.pendingDeadlines.contains(0.3) }
        clock.advance(by: 0.299)
        XCTAssertNil(model.pendingHardwareConnection)
        clock.advance(by: 0.001)
        try await waitUntil { model.pendingHardwareConnection != nil }
        XCTAssertTrue(midi.sent.isEmpty)
    }
}
