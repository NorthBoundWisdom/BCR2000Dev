import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
final class FunctionEditorTests: XCTestCase {
    func testCycleTextValidationKeepsExistingAssignmentOnBadInput() throws {
        let stores = ConsoleStores.temporary()
        defer { try? FileManager.default.removeItem(at: stores.configuration.fileURL.deletingLastPathComponent()) }
        let model = ConsoleViewModel(stores: stores, startsMIDI: false)
        let control = BCRControlID.userButton(1)
        let before = model.configuration
        model.setCycleValues("0, not-a-number", parameter: "arm.j1", for: control)
        XCTAssertEqual(model.configuration, before)
        XCTAssertEqual(model.notice?.level, .error)
        model.setCycleValues("-90，0，90", parameter: "arm.j1", for: control)
        XCTAssertEqual(model.configuration.assignment(for: control)?.target, .cycleParameter(id: "arm.j1", values: [-90, 0, 90]))
        let valid = model.configuration
        model.setCycleValues("0, 0", parameter: "arm.j1", for: control)
        XCTAssertEqual(model.configuration, valid)
    }

    func testBulkModelReportsStalePreviewAndCurrentValuesSurviveSuccess() throws {
        let stores = ConsoleStores.temporary()
        defer { try? FileManager.default.removeItem(at: stores.configuration.fileURL.deletingLastPathComponent()) }
        let model = ConsoleViewModel(stores: stores, startsMIDI: false)
        let plan = try XCTUnwrap(model.bulkAssignmentPlan(section: .encoder, row: 1, group: SurfaceConfiguration.robotArmGroup))
        model.setParameter("arm.j1", to: 40)
        XCTAssertTrue(model.applyBulkAssignment(plan))
        XCTAssertEqual(model.engine.value(of: "arm.j1"), 40)
        XCTAssertFalse(model.applyBulkAssignment(plan))
        XCTAssertEqual(model.notice?.level, .error)
    }
}
