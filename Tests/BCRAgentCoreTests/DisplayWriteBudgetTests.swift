import BCRMCPAdapter
import Foundation
import XCTest

@MainActor
final class DisplayWriteBudgetTests: XCTestCase {
    func testDisplayWritersAndOwnerHaveIndependentBudgetsOnlyWhenExplicitlySelected() throws {
        let gateway = MCPApplicationGateway(permissions: .init(writesPerSecond: 1))
        try gateway.withAuthenticatedSurfaceWriterID("display-a", displayWriteLimit: 1) {
            try gateway.consumeWrites(1)
            XCTAssertThrowsError(try gateway.consumeWrites(1))
        }
        try gateway.withAuthenticatedSurfaceWriterID("display-b", displayWriteLimit: 1) {
            try gateway.consumeWrites(1)
            XCTAssertThrowsError(try gateway.consumeWrites(1))
        }
        try gateway.consumeWrites(1)
        XCTAssertThrowsError(try gateway.consumeWrites(1))
        XCTAssertFalse(gateway.hasIndependentDisplayBudget)
    }

    func testAbsentFlagRetainsSharedAggregateAcrossWriters() throws {
        let gateway = MCPApplicationGateway(permissions: .init(writesPerSecond: 1))
        try gateway.withAuthenticatedSurfaceWriterID("display-a") { try gateway.consumeWrites(1) }
        try gateway.withAuthenticatedSurfaceWriterID("display-b") {
            XCTAssertThrowsError(try gateway.consumeWrites(1))
        }
        XCTAssertThrowsError(try gateway.consumeWrites(1))
    }

    func testOneSecondWindowBoundaryAndExplicitLifecycleClear() throws {
        var time = 100.0
        let gateway = MCPApplicationGateway(displayMonotonic: { time })
        try gateway.withAuthenticatedSurfaceWriterID("display-a", displayWriteLimit: 1) {
            try gateway.consumeWrites(1)
            time += 0.999
            XCTAssertThrowsError(try gateway.consumeWrites(1))
            time = 101
            try gateway.consumeWrites(1)
            XCTAssertThrowsError(try gateway.consumeWrites(1))
            gateway.clearDisplayBudgets()
            try gateway.consumeWrites(1)
        }
    }

    func testNestedAndThrowingAuthenticationRestoresWriterAndBudgetContext() throws {
        enum Expected: Error { case failure }
        let gateway = MCPApplicationGateway(permissions: .init(writesPerSecond: 1))
        try gateway.withAuthenticatedSurfaceWriterID("display-a", displayWriteLimit: 1) {
            XCTAssertThrowsError(try gateway.withAuthenticatedSurfaceWriterID("display-b", displayWriteLimit: 2) {
                try gateway.consumeWrites(2)
                throw Expected.failure
            })
            XCTAssertEqual(gateway.authenticatedSurfaceWriterID, "display-a")
            try gateway.consumeWrites(1)
            XCTAssertThrowsError(try gateway.consumeWrites(1))
        }
        XCTAssertNil(gateway.authenticatedSurfaceWriterID)
        XCTAssertFalse(gateway.hasIndependentDisplayBudget)
        try gateway.consumeWrites(1)
    }

    func testWallClockJumpsDoNotAffectDisplayAndMonotonicRollbackFailsClosed() throws {
        var wall = Date(timeIntervalSinceReferenceDate: 100)
        var monotonic = 10.0
        let gateway = MCPApplicationGateway(now: { wall }, displayMonotonic: { monotonic })
        try gateway.withAuthenticatedSurfaceWriterID("display-a", displayWriteLimit: 1) {
            try gateway.consumeWrites(1)
            for changedWall in [200_000.0, -200_000.0] {
                wall = Date(timeIntervalSinceReferenceDate: changedWall)
                XCTAssertThrowsError(try gateway.consumeWrites(1))
            }
        }
        for invalid in [9.0, Double.nan, Double.infinity] {
            monotonic = invalid
            try gateway.withAuthenticatedSurfaceWriterID("display-b", displayWriteLimit: 1) {
                XCTAssertThrowsError(try gateway.consumeWrites(1)) { error in
                    XCTAssertEqual(error as? MCPApplicationGateway.DisplayClockFailure, .invalidTime)
                }
            }
        }
        monotonic = 10
        try gateway.withAuthenticatedSurfaceWriterID("display-b", displayWriteLimit: 1) {
            try gateway.consumeWrites(1)
            XCTAssertThrowsError(try gateway.consumeWrites(1))
        }
        try gateway.withAuthenticatedSurfaceWriterID("display-a", displayWriteLimit: 1) {
            XCTAssertThrowsError(try gateway.consumeWrites(1))
        }
    }
}
