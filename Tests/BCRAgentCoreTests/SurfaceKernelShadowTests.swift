@testable import BCRSurfaceDomain
import BCRFoundation
import Foundation
import XCTest

final class SurfaceKernelShadowTests: XCTestCase {
    func testFirstMatchKeepsDistinctLogicalFacetsOfOnePhysicalRole() {
        let first = BCRControlID.pushEncoder(group: 1, 1), second = BCRControlID.pushEncoder(group: 2, 1)
        let assignments: [ControlAssignment] = [
            .init(control: first, target: .parameter("p")),
            .init(control: first, target: .parameter("q")),
            .init(control: second, target: .parameter("q"))
        ]
        let configuration = SurfaceConfiguration(name: "fixture", parameters: [
            .init(id: "p", name: "p"), .init(id: "q", name: "q")
        ], assignments: assignments)
        XCTAssertEqual(configuration.assignment(for: first)?.target, .parameter("p"))
        XCTAssertEqual(configuration.assignment(for: second)?.target, .parameter("q"))
        XCTAssertNil(configuration.assignment(for: .pushEncoder(group: 3, 1)))
    }

    func testIndexRetainsFullOptionalScopeWhenSameIDIsReplacedWithoutReordering() throws {
        var scheduler = try FeedbackScheduler(policy: .init(enabled: true, messagesPerSecond: 10, burst: 1))
        let one = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 1)
        let newest = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 9)
        let two = MIDIVoiceMessage.controlChange(channel: 0, number: 82, value: 2)
        let endpoint = MIDIEndpointSource(endpointID: "unknown", connectionGeneration: 7, provenance: .unknown)
        let context = SurfaceEventContext(generation: "actual-epoch", mappingGeneration: 3)
        scheduler.enqueue(one, origin: .software)
        scheduler.enqueue(two, origin: .external, endpoint: endpoint, mappingRevision: 3, source: .hardware,
                          context: context)
        scheduler.enqueue(newest, origin: .agent, endpoint: endpoint, mappingRevision: 3, source: .hardware,
                          context: context)
        XCTAssertEqual(scheduler.pendingItems.map(\.message), [newest, two])
        XCTAssertEqual(scheduler.pendingItems.map(\.context), [context, context])
        XCTAssertEqual(scheduler.pendingItems.map(\.source), [.hardware, .hardware])
        let drained = scheduler.drain(at: Date(timeIntervalSinceReferenceDate: 123))
        XCTAssertEqual(drained.map(\.message), [newest])
        XCTAssertEqual(drained.first?.endpoint, endpoint)
        scheduler.cancel(one.controlID)
        XCTAssertEqual(scheduler.pendingItems.map(\.message), [two])
        scheduler.clear()
        XCTAssertTrue(scheduler.pendingItems.isEmpty)
    }
}
