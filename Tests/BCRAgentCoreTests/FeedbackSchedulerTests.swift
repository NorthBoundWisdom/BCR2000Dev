import Foundation
import XCTest
@testable import BCRAgentCore

final class FeedbackSchedulerTests: XCTestCase {
    func testCoalescesControlsAndRespectsGlobalRate() throws {
        var scheduler = try FeedbackScheduler(policy: .init(enabled: true, messagesPerSecond: 10, burst: 1))
        let a = MIDIVoiceMessage.controlChange(channel: 1, number: 1, value: 1)
        let newest = MIDIVoiceMessage.controlChange(channel: 1, number: 1, value: 90)
        let b = MIDIVoiceMessage.controlChange(channel: 1, number: 2, value: 20)
        scheduler.enqueue(a, origin: .software)
        scheduler.enqueue(newest, origin: .agent)
        scheduler.enqueue(b, origin: .external)
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(scheduler.drain(at: now), [.init(message: newest, origin: .agent)])
        XCTAssertTrue(scheduler.drain(at: now.addingTimeInterval(0.05)).isEmpty)
        XCTAssertEqual(scheduler.drain(at: now.addingTimeInterval(0.11)).map(\.message), [b])
    }

    func testErrorCooldownClockRollbackAndClearPreventReplay() throws {
        var scheduler = try FeedbackScheduler(policy: .init(enabled: true, messagesPerSecond: 10, burst: 1))
        let now = Date(timeIntervalSince1970: 100)
        let message = MIDIVoiceMessage.controlChange(channel: 1, number: 1, value: 1)
        scheduler.enqueue(message, origin: .software)
        scheduler.noteFailure(at: now)
        XCTAssertTrue(scheduler.drain(at: now.addingTimeInterval(0.5)).isEmpty)
        XCTAssertEqual(scheduler.drain(at: now.addingTimeInterval(1.1)).count, 1)
        scheduler.enqueue(message, origin: .software)
        XCTAssertTrue(scheduler.drain(at: now.addingTimeInterval(-1)).isEmpty)
        scheduler.clear()
        XCTAssertTrue(scheduler.drain(at: now.addingTimeInterval(100)).isEmpty)
    }

    func testInvalidPolicyFails() {
        XCTAssertThrowsError(try FeedbackScheduler(policy: .init(messagesPerSecond: 0)))
        XCTAssertThrowsError(try FeedbackScheduler(policy: .init(errorCooldown: .nan)))
    }
}
