import XCTest
@testable import BCRAgentConsole

final class ConsoleLayoutTests: XCTestCase {
    func testMinimumWindowKeepsNaturalPanelStacked() {
        // 1200 × 760 window minus a 330 pt inspector and the header.
        let layout = ConsoleLayout(available: CGSize(width: 869, height: 650))
        XCTAssertFalse(layout.isSideBySide)
        XCTAssertEqual(layout.scale, 1)
        XCTAssertEqual(layout.workspaceWidth, layout.panelWidth)
    }

    func testWideWindowPlacesWorkspaceBesideAScaledPanel() {
        let available = CGSize(width: 1_345, height: 975)
        let layout = ConsoleLayout(available: available)
        XCTAssertTrue(layout.isSideBySide)
        XCTAssertGreaterThan(layout.scale, 1)
        XCTAssertGreaterThanOrEqual(layout.workspaceWidth, ConsoleLayout.minWorkspace)
        XCTAssertLessThanOrEqual(layout.contentWidth, available.width - ConsoleLayout.padding * 2 + 0.5)
    }

    func testTallNarrowWindowGrowsPanelButKeepsWorkspaceVisible() {
        let available = CGSize(width: 1_100, height: 1_400)
        let layout = ConsoleLayout(available: available)
        XCTAssertFalse(layout.isSideBySide)
        XCTAssertGreaterThan(layout.scale, 1)
        XCTAssertLessThanOrEqual(layout.panelWidth, available.width - ConsoleLayout.padding * 2 + 0.5)
    }

    func testScaleIsCappedAndContentNeverExceedsAvailableWidth() {
        for size in [CGSize(width: 2_400, height: 1_500), CGSize(width: 4_000, height: 2_200), CGSize(width: 1_500, height: 700)] {
            let layout = ConsoleLayout(available: size)
            XCTAssertLessThanOrEqual(layout.scale, PanelMetrics.scaleRange.upperBound)
            XCTAssertGreaterThanOrEqual(layout.scale, PanelMetrics.scaleRange.lowerBound)
            XCTAssertLessThanOrEqual(layout.contentWidth, size.width - ConsoleLayout.padding * 2 + 0.5, "\(size)")
            XCTAssertLessThanOrEqual(layout.workspaceWidth, max(ConsoleLayout.maxWorkspace, layout.panelWidth))
        }
    }

    func testPanelHeightFitsWhenSideBySide() {
        let size = CGSize(width: 2_000, height: 900)
        let layout = ConsoleLayout(available: size)
        XCTAssertTrue(layout.isSideBySide)
        XCTAssertLessThanOrEqual(PanelMetrics.naturalSize.height * layout.scale, size.height - ConsoleLayout.padding * 2 + 0.5)
    }
}
