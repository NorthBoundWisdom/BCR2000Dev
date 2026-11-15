import BCRFoundation
import XCTest
@testable import BCRSurfaceDomain

@MainActor
final class FeedbackPlanTests: XCTestCase {
    func testPlanTimingSelectsExistingDispatchWithoutSessionMutation() {
        let message = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 64)
        for origin in [SurfaceWriteOrigin.software, .agent, .external] {
            let regular = FeedbackPlan(message: message, origin: origin, timing: .coalesced)
            let acknowledged = FeedbackPlan(message: message, origin: origin, timing: .synchronous)
            XCTAssertEqual(FeedbackScheduler.dispatch(regular, canCoalesce: true), .enqueue)
            XCTAssertEqual(FeedbackScheduler.dispatch(regular, canCoalesce: false), .send)
            XCTAssertEqual(FeedbackScheduler.dispatch(acknowledged, canCoalesce: true), .send)
            XCTAssertEqual(FeedbackScheduler.dispatch(acknowledged, canCoalesce: false), .send)
            XCTAssertEqual(acknowledged.message, message)
            XCTAssertEqual(acknowledged.origin, origin)
        }
    }

    func testPlannerRestoresTimingAfterThrowAndRetainsEachChildOrigin() throws {
        enum FixtureFailure: Error { case expected }
        let planner = FeedbackPlanner()
        let message = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 64)
        let batch = FeedbackBatchPlan(effects: [.send(message)], origin: .external, timing: .synchronous)
        XCTAssertThrowsError(try planner.withBatch(batch) {
            let child = planner.message(message, origin: .software, requestedTiming: nil)
            XCTAssertEqual(child.timing, .synchronous)
            XCTAssertEqual(child.origin, .software)
            throw FixtureFailure.expected
        })
        XCTAssertEqual(planner.message(message, origin: .agent, requestedTiming: nil).timing, .coalesced)
        XCTAssertEqual(planner.message(message, origin: .agent, requestedTiming: nil).origin, .agent)
    }
}
