import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
final class ParameterColorPresentationTests: XCTestCase {
    func testColorAndGroupHighlightReachEveryAssignedControlAndAccessibleText() throws {
        let model = ConsoleViewModel(
            stores: .temporary(),
            startsMIDI: false,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
        model.setParameterColor(.purple, for: "general.1")
        let group = try XCTUnwrap(model.configuration.parameter("general.1")?.group)
        model.highlightGroup(group)
        let presentation = model.presentation(of: .pushEncoder(group: 1, 1))
        XCTAssertEqual(presentation.color, .purple)
        XCTAssertTrue(presentation.isHighlighted)
        XCTAssertTrue(presentation.accessibilitySummary.contains(ParameterColor.purple.title))
        XCTAssertTrue(presentation.accessibilitySummary.contains(L10n.text("分组高亮")))
        XCTAssertFalse(model.presentation(of: .encoder(row: 1, 1)).isHighlighted)
        model.highlightGroup(nil)
        XCTAssertFalse(model.presentation(of: .pushEncoder(group: 1, 1)).isHighlighted)
    }

    func testColorPersistsInExportAndLibraryButHighlightDoesNot() throws {
        let stores = ConsoleStores.temporary()
        let model = ConsoleViewModel(
            stores: stores,
            startsMIDI: false,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
        model.setParameterColor(.teal, for: "general.1")
        model.highlightGroup(model.configuration.parameters[0].group)
        XCTAssertTrue(model.library.save(name: "Colors", configuration: model.configuration))
        let path = stores.configuration.fileURL.deletingLastPathComponent().appending(path: "color-export.json")
        try model.exportConfiguration(to: path)
        XCTAssertEqual(try ConfigurationTransfer.decode(Data(contentsOf: path)).parameter("general.1")?.color, .teal)
        let reopened = ConsoleViewModel(
            stores: stores,
            startsMIDI: false,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
        XCTAssertEqual(reopened.configuration.parameter("general.1")?.color, .teal)
        XCTAssertEqual(reopened.library.entries.first?.configuration.parameter("general.1")?.color, .teal)
        XCTAssertNil(reopened.highlightedGroup)
    }
}
