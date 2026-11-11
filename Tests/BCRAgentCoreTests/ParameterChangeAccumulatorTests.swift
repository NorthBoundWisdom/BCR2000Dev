import XCTest
@testable import BCRAgentCore
@testable import BCRMCPAdapter
@testable import BCRSurfaceDomain

final class ParameterChangeAccumulatorTests: XCTestCase {
    func testCoalescesLatestValuesRemovalsAndResets() throws {
        var accumulator = ParameterChangeAccumulator()
        accumulator.append(.init(revision: 1, values: ["a": 1, "b": 1], removed: [], reset: false))
        accumulator.append(.init(revision: 2, values: ["b": 2], removed: ["a"], reset: false))
        accumulator.append(.init(revision: 3, values: ["a": 3], removed: [], reset: false))
        let batch = try XCTUnwrap(accumulator.take())
        XCTAssertEqual(batch.values, ["a": 3, "b": 2])
        XCTAssertTrue(batch.removed.isEmpty)
        XCTAssertEqual(batch.revision, 3)
        XCTAssertNil(accumulator.take())
        accumulator.append(.init(revision: 4, values: ["a": 10], removed: [], reset: false))
        accumulator.append(.init(revision: 5, values: ["c": 5], removed: [], reset: true))
        let reset = try XCTUnwrap(accumulator.take())
        XCTAssertEqual(reset.values, ["c": 5])
        XCTAssertTrue(reset.reset)
    }
}
