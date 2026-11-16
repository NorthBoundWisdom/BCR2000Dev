import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
final class ParameterSceneWorkspaceTests: XCTestCase {
    func testScenesSurviveExportImportLibraryAndRelaunchWithoutRestoringValues() throws {
        let stores = ConsoleStores.temporary()
        let model = ConsoleViewModel(
            stores: stores,
            startsMIDI: false,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
        model.setParameter("general.1", to: 70)
        model.captureScene(name: "我的 Intro")
        let scene = try XCTUnwrap(model.configuration.scenes?.first)
        XCTAssertEqual(scene.values["general.1"], 70)
        model.setParameter("general.1", to: 15)
        model.recallScene(scene.id)
        XCTAssertEqual(model.engine.value(of: "general.1"), 70)
        model.undo(); XCTAssertEqual(model.engine.value(of: "general.1"), 15)
        XCTAssertTrue(model.library.save(name: "Scenes", configuration: model.configuration))
        let url = stores.configuration.fileURL.deletingLastPathComponent().appending(path: "scene-export.json")
        try model.exportConfiguration(to: url)
        let exported = try ConfigurationTransfer.decode(Data(contentsOf: url))
        XCTAssertEqual(exported.scenes, model.configuration.scenes)
        XCTAssertTrue(model.installConfiguration(exported))
        XCTAssertFalse(model.canUndo)
        let reopened = ConsoleViewModel(
            stores: stores,
            startsMIDI: false,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
        XCTAssertEqual(reopened.configuration.scenes, [scene])
        XCTAssertEqual(reopened.library.entries.first?.configuration.scenes, [scene])
        XCTAssertEqual(reopened.engine.value(of: "general.1"), 0, "Scenes persist; active values remain session state")
    }

    func testMissingSceneParametersProduceVisibleNotice() throws {
        let model = ConsoleViewModel(
            stores: .temporary(),
            startsMIDI: false,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
        model.captureScene(name: "Before deletion")
        let scene = try XCTUnwrap(model.configuration.scenes?.first)
        model.removeParameter("general.2")
        model.recallScene(scene.id)
        XCTAssertEqual(model.notice?.text, L10n.text("场景已调用；跳过不存在的参数：\("general.2")"))
        XCTAssertNil(model.engine.value(of: "general.2"))
    }
}
