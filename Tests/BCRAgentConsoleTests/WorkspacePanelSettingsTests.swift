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
        XCTAssertTrue(model.notice?.text.contains("面板设置读取失败") == true)
        // The unreadable file is left untouched until the user makes an explicit choice.
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"version":1,"enabled":["hologram"]}"#)

        XCTAssertFalse(model.setWorkspacePanel(.monitor, enabled: true))
        XCTAssertEqual(model.workspacePanels, WorkspacePanelSettings())
        XCTAssertTrue(model.notice?.text.contains("面板设置保存失败") == true)
    }
}
