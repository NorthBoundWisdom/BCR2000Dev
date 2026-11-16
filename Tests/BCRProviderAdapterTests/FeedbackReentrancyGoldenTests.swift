import BCRFoundation
import BCRSurfaceDomain
import Foundation
import XCTest

@MainActor
final class FeedbackReentrancyGoldenTests: XCTestCase {
    private final class Device: SurfaceDevice {
        var connection = MIDIConnectionSnapshot(connectedSource: "fake-in", connectedDestination: "fake-out")
        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        var sent: [MIDIVoiceMessage] = []
        var callback: ((MIDIVoiceMessage) -> Void)?
        func send(_ message: MIDIVoiceMessage) throws { sent.append(message); callback?(message) }
    }

    func testSynchronousReentrancyPreservesPendingAndCompleteOldOutputOrder() async throws {
        var captured: [String: JSONValue] = [:]
        for callbackKind in [
            "send_callback",
            "journal_observer",
            "publish_callback",
            "nested_send_callback",
            "nested_journal_observer",
            "nested_publish_callback"
        ] {
            let device = Device()
            var map = HardwareMap()
            try map.bind(.encoder(row: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 81))
            let session = SurfaceSession(hardwareDevice: device, hardwareMap: map,
                                         configuration: .init(name: "Reentrant", parameters: [
                                             .init(id: "p", name: "p", minimum: 0, maximum: 127, defaultValue: 10)
                                         ], assignments: [.init(
                                             control: .encoder(row: 1, 1),
                                             target: .parameter("p")
                                         )]),
                                         hardwareOutput: .write, hardwareLifecycleFeedback: false,
                                         now: { Date(timeIntervalSinceReferenceDate: 1000) },
                                         saveHardwareMap: { _ in }, saveConfiguration: { _ in })
            session.selectSource(.hardware)
            try session.configureFeedback(.init(enabled: true, messagesPerSecond: 1000, burst: 128))
            session.setParameter("p", to: 20)
            XCTAssertEqual(session.pendingFeedbackCount, 1)
            var called = false
            var observer: UUID?
            let nested = callbackKind.hasPrefix("nested_")
            let kind = callbackKind.replacingOccurrences(of: "nested_", with: "")
            func reenter() {
                called = true
                if nested {
                    do { try session.setHardwareDisplayFeedback(.encoder(row: 1, 1), rawValue: 55) }
                    catch { XCTFail("Nested display failed: \(error)") }
                }
                session.setParameter("p", to: 33)
            }
            if kind == "send_callback" {
                device.callback = { message in
                    if message.dataValue == 64, !called { reenter() }
                }
            } else if kind == "journal_observer" {
                observer = session.inputEvents.observe { delta in
                    guard let events = delta.objectValue?["events"]?.arrayValue else { return }
                    if events.contains(where: { $0.objectValue?["kind"] == .string("feedback.sent") &&
                            $0.objectValue?["payload"]?.objectValue?["raw_value"] == .number(64)
                    }), !called {
                        reenter()
                    }
                }
            }
            if kind == "publish_callback" {
                session.onChange = {
                    if !called { reenter() }
                }
            }
            try session.setHardwareDisplayFeedback(.encoder(row: 1, 1), rawValue: 64)
            XCTAssertTrue(called)
            session.flushFeedback()
            if let observer { session.inputEvents.removeObserver(observer) }
            device.callback = nil
            session.onChange = nil
            let journal = session.events.filter { $0.direction == .output }
            captured[callbackKind] = .object([
                "sent": try .encoded(device.sent.map(\.midi1Bytes)),
                "journal": try .encoded(journal.map { $0.message.midi1Bytes }),
                "origins": try .encoded(journal.map { $0.origin.rawValue })
            ])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(JSONValue.object(captured))
        if let path = ProcessInfo.processInfo.environment["BCR_G6_CAPTURE_REENTRANT"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FeedbackOutput/g6-reentrant.json")
        XCTAssertEqual(.object(captured), try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path)))
    }
}
