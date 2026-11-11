import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

@MainActor
private final class FeedbackDevice: SurfaceDevice {
    let connection = MIDIConnectionSnapshot(connectedSource: "fixture", connectedDestination: "fixture")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func send(_ message: MIDIVoiceMessage) throws {}
}

@MainActor
final class FeedbackSettingsTests: XCTestCase {
    func testPollingRunsOnlyForEnabledNonemptyQueueAndReleasesController() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SurfaceSession(hardwareDevice: FeedbackDevice(), hardwareMap: .mockPreset(),
                                     configuration: .robotArmDemo(), saveHardwareMap: { _ in },
                                     saveConfiguration: { _ in })
        session.selectSource(.hardware)
        var controller: FeedbackSettingsController? = FeedbackSettingsController(
            session: session,
            url: directory.appending(path: "policy.json")
        )
        XCTAssertFalse(try XCTUnwrap(controller).isPolling)
        controller?.apply(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
        XCTAssertTrue(try XCTUnwrap(controller).isPolling)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(session.pendingFeedbackCount, 0)
        XCTAssertFalse(try XCTUnwrap(controller).isPolling)
        session.setParameter("arm.j1", to: 50)
        XCTAssertTrue(try XCTUnwrap(controller).isPolling)
        controller?.apply(.init(enabled: false))
        XCTAssertFalse(try XCTUnwrap(controller).isPolling)
        weak var weakController = controller
        controller = nil
        XCTAssertNil(weakController)
        weakController = nil
    }
}
