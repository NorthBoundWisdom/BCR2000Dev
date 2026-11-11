import BCRAgentCore
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

final class ParameterDraftTests: XCTestCase {
    func testPristineDraftRefreshesWhenSameParameterChangesExternally() {
        let original = ParameterDefinition(id: "x", name: "Original")
        var state = ParameterDraftState(original)
        var newer = original
        newer.name = "External"
        state.receive(newer)
        XCTAssertEqual(state.value, newer)
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.conflict)
    }

    func testDirtyDraftRetainsEditsAndRequiresExplicitConflictResolution() {
        let original = ParameterDefinition(id: "x", name: "Original")
        var state = ParameterDraftState(original)
        state.value.name = "Mine"
        var newer = original
        newer.name = "External"
        state.receive(newer)
        XCTAssertEqual(state.value.name, "Mine")
        XCTAssertEqual(state.conflict, newer)
        state.keepDraft()
        XCTAssertNil(state.conflict)
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(state.baseline, newer)
        XCTAssertEqual(state.value.name, "Mine")
    }

    func testReloadAndMatchingExternalSaveClearDraft() {
        let original = ParameterDefinition(id: "x", name: "Original")
        var state = ParameterDraftState(original)
        state.value.name = "Mine"
        state.receive(state.value)
        XCTAssertFalse(state.isDirty)
        XCTAssertNil(state.conflict)
        state.value.name = "Another"
        state.reload(original)
        XCTAssertEqual(state.value, original)
        XCTAssertFalse(state.isDirty)
    }

    func testExternalRevertClearsConflictWithoutDiscardingLocalEdits() {
        let original = ParameterDefinition(id: "x", name: "Original")
        var state = ParameterDraftState(original)
        state.value.name = "Mine"
        var external = original
        external.maximum = 90
        state.receive(external)
        XCTAssertNotNil(state.conflict)
        state.receive(original)
        XCTAssertNil(state.conflict)
        XCTAssertEqual(state.value.name, "Mine")
        XCTAssertTrue(state.isDirty)
    }
}
