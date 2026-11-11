import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
final class WorkspacePanelSettingsTests: XCTestCase {
    private func stores(_ directory: URL) -> ConsoleStores {
        .init(hardwareMap: JSONFileStore(fileURL: directory.appending(path: "map.json")),
              configuration: JSONFileStore(fileURL: directory.appending(path: "config.json")))
    }

    private func decode(_ json: String) throws -> WorkspacePanelSettings {
        try JSONDecoder().decode(WorkspacePanelSettings.self, from: Data(json.utf8))
    }

    func testSpecialistPanelsAreHiddenUntilEnabled() throws {
        var settings = WorkspacePanelSettings()
        XCTAssertEqual(settings.visibleTabs(outputActive: false), [.parameters, .agents, .monitor])
        XCTAssertEqual(WorkspaceTab.optional, [.arm, .output])

        try settings.set(.output, enabled: true)
        try settings.set(.arm, enabled: true)
        try settings.set(.arm, enabled: true)
        XCTAssertEqual(settings.enabled, [.arm, .output])
        XCTAssertEqual(settings.visibleTabs(outputActive: false), WorkspaceTab.allCases)

        try settings.set(.arm, enabled: false)
        XCTAssertEqual(settings.visibleTabs(outputActive: false), [.parameters, .agents, .monitor, .output])
        XCTAssertThrowsError(try settings.set(.parameters, enabled: false))
    }

    func testRunningOutputKeepsItsReadoutVisible() {
        let settings = WorkspacePanelSettings()
        XCTAssertEqual(settings.visibleTabs(outputActive: true), [.parameters, .agents, .monitor, .output])
        XCTAssertEqual(settings.resolved(.output, outputActive: true), .output)
        XCTAssertEqual(settings.resolved(.output, outputActive: false), .parameters)
        XCTAssertEqual(settings.resolved(.arm, outputActive: true), .parameters)
        XCTAssertEqual(settings.resolved(.monitor, outputActive: false), .monitor)
    }

    func testDecodingRejectsUnknownCoreDuplicateAndFutureVersions() throws {
        XCTAssertEqual(try decode(#"{"version":1,"enabled":["output","arm"]}"#).enabled, [.arm, .output])
        XCTAssertThrowsError(try decode(#"{"version":2,"enabled":[]}"#))
        XCTAssertThrowsError(try decode(#"{"version":1,"enabled":["parameters"]}"#))
        XCTAssertThrowsError(try decode(#"{"version":1,"enabled":["arm","arm"]}"#))
        XCTAssertThrowsError(try decode(#"{"version":1,"enabled":["hologram"]}"#))
        XCTAssertThrowsError(try decode(#"{"enabled":["arm"]}"#))
    }

    func testChoicePersistsAcrossLaunches() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ConsoleViewModel(stores: stores(directory), startsMIDI: false)
        XCTAssertEqual(first.workspacePanels, WorkspacePanelSettings())
        XCTAssertTrue(first.setWorkspacePanel(.arm, enabled: true))

        let second = ConsoleViewModel(stores: stores(directory), startsMIDI: false)
        XCTAssertTrue(second.workspacePanels.isEnabled(.arm))
        XCTAssertFalse(second.workspacePanels.isEnabled(.output))
        XCTAssertNil(second.notice)
    }

    func testRejectedOrCorruptSettingsStayVisibleAndKeepPanelsHidden() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "workspace-panels.json")
        try Data(#"{"version":1,"enabled":["hologram"]}"#.utf8).write(to: file)

        let model = ConsoleViewModel(stores: stores(directory), startsMIDI: false)
        XCTAssertEqual(model.workspacePanels, WorkspacePanelSettings())
        XCTAssertEqual(model.notice?.level, .error)
        XCTAssertTrue(model.notice?.text
            .contains(L10n.language == .chinese ? "面板设置读取失败" : "Could not read panel settings") == true)
        // The unreadable file is left untouched until the user makes an explicit choice.
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"version":1,"enabled":["hologram"]}"#)

        XCTAssertFalse(model.setWorkspacePanel(.monitor, enabled: true))
        XCTAssertEqual(model.workspacePanels, WorkspacePanelSettings())
        XCTAssertTrue(model.notice?.text
            .contains(L10n.language == .chinese ? "面板设置保存失败" : "Could not save panel settings") == true)
    }
}

@MainActor
final class ConfigurationPresetTests: XCTestCase {
    private func stores() -> ConsoleStores {
        .temporary()
    }

    func testFreshInstallOpensNeutralStarterAndExampleIsLoadedExplicitly() throws {
        let stores = stores()
        defer { try? FileManager.default.removeItem(at: stores.configuration.fileURL.deletingLastPathComponent()) }
        let model = ConsoleViewModel(stores: stores, startsMIDI: false)
        XCTAssertEqual(model.configuration, .starter())
        XCTAssertNil(model.configuration.parameter("arm.j1"))
        // Without a toggle parameter, output refuses to start and says why.
        model.output.start()
        XCTAssertFalse(model.output.settings.enabled)
        XCTAssertNotNil(model.output.error)

        model.loadPreset(.robotArm)
        XCTAssertEqual(model.configuration, .robotArmDemo())
        XCTAssertTrue(model.notice?.text.contains(L10n.text("可从工作区“面板”菜单启用机械臂预览。")) == true)

        XCTAssertTrue(model.setWorkspacePanel(.arm, enabled: true))
        model.loadPreset(.starter)
        XCTAssertEqual(model.configuration, .starter())
        model.loadPreset(.robotArm)
        XCTAssertEqual(model.notice?.text, L10n.text("已载入“\(ConfigurationPreset.robotArm.title)”。"))
    }

    func testSavedConfigurationWinsOverTheInitialPreset() throws {
        let stores = stores()
        defer { try? FileManager.default.removeItem(at: stores.configuration.fileURL.deletingLastPathComponent()) }
        let first = ConsoleViewModel(stores: stores, startsMIDI: false, initialPreset: .robotArm)
        XCTAssertEqual(first.configuration, .robotArmDemo())
        first.createParameter()
        let saved = first.configuration

        let second = ConsoleViewModel(stores: stores, startsMIDI: false)
        XCTAssertEqual(second.configuration, saved)
    }
}
