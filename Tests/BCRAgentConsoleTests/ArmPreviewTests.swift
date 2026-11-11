import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole

final class ArmPreviewTests: XCTestCase {
    func testExtremeFiniteAnglesFormatWithoutIntegerNarrowingAndHaveFiniteGeometry() {
        for value in [
            Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude,
            1e30,
            -1e30,
            Double(Int.max),
            Double(Int.min),
            0,
            45
        ] {
            XCTAssertFalse(ArmPreviewNumbers.text(value).isEmpty)
            let radians = ArmPreviewNumbers.radians(value)
            XCTAssertTrue(radians.isFinite)
            XCTAssertLessThanOrEqual(abs(radians), 2 * .pi)
            XCTAssertTrue(sin(radians).isFinite)
        }
        XCTAssertEqual(ArmPreviewNumbers.text(.infinity), L10n.text("无效值"))
        XCTAssertEqual(ArmPreviewNumbers.text(.nan), L10n.text("无效值"))
    }
}
