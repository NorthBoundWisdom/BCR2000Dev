import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

@MainActor
private final class SystemLanguageFixture {
    var values = ["zh-Hans"]
}

final class LanguagePreferencesTests: XCTestCase {
    func testPreferencePersistsAndReturningToSystemRemovesOnlyAppOverride() throws {
        let suite = "BCRLocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage.saved(in: defaults), .system)
        defaults.set("kept", forKey: "unrelated")
        for choice in [AppLanguage.chinese, .english, .system] {
            choice.save(in: defaults)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(AppLanguage.saved(in: reopened), choice)
            let domain = try XCTUnwrap(reopened.persistentDomain(forName: suite))
            XCTAssertEqual(domain["AppleLanguages"] as? [String], choice == .system ? nil : [choice.rawValue])
            XCTAssertEqual(reopened.string(forKey: "unrelated"), "kept")
        }
        defaults.set("unknown-future-language", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .system)
    }

    @MainActor
    func testRuntimeSelectionUpdatesExistingTextAndNoticesAndKeepsTheSession() throws {
        let original = L10n.language
        defer { L10n.setLanguage(original) }
        let suite = "BCRLanguageRuntime.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: { ["zh-Hans"] })
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false, initialPreset: .robotArm,
                                     automaticallyAdvancesMock: false)
        model.setParameter("arm.j1", to: 37)
        let configuration = model.configuration, epoch = model.provider.runtime.epoch
        let values = model.engine.parameterValues
        let userName = "My 参数 {0}"
        let notice = ConsoleNotice(level: .warning, message: "参数“\(userName)”已更新。")
        XCTAssertEqual(settings.language, .chinese)
        XCTAssertEqual(notice.text, "参数“\(userName)”已更新。")
        settings.selection = .english
        XCTAssertEqual(L10n.text("设置"), "Settings")
        XCTAssertEqual(notice.text, "Parameter “\(userName)” updated.")
        XCTAssertEqual(AppLanguage.saved(in: defaults), .english)
        settings.selection = .chinese
        XCTAssertEqual(notice.text, "参数“\(userName)”已更新。")
        XCTAssertEqual(model.configuration, configuration)
        XCTAssertEqual(model.provider.runtime.epoch, epoch)
        XCTAssertEqual(model.engine.parameterValues, values)
        XCTAssertEqual(model.engine.value(of: "arm.j1"), 37)
    }

    @MainActor
    func testSystemSelectionRefreshesAndIgnoresThePriorAppOverride() throws {
        let original = L10n.language
        defer { L10n.setLanguage(original) }
        let suite = "BCRLanguageSystem.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let languages = SystemLanguageFixture()
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: { languages.values })
        settings.selection = .english
        languages.values = ["zh-Hans"]
        settings.selection = .system
        XCTAssertEqual(settings.language, .chinese)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
        languages.values = ["en"]
        settings.refreshSystemLanguage()
        XCTAssertEqual(settings.language, .english)
        settings.selection = .chinese
        settings.refreshSystemLanguage()
        XCTAssertEqual(settings.language, .chinese)
    }

    @MainActor
    func testSmokeLanguageOverrideDoesNotChangeTheSavedUserSelection() throws {
        let original = L10n.language
        defer { L10n.setLanguage(original) }
        let suite = "BCRLanguageSmoke.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppLanguage.chinese.save(in: defaults)
        let settings = LanguageSettings(defaults: defaults, initialSelection: .system, preferredLanguages: { ["en"] })
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(AppLanguage.saved(in: defaults), .chinese)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String], ["zh-Hans"])
    }
}

extension LanguagePreferencesTests {
    @MainActor
    func testRetainedPresetFailureAndNestedErrorDetailsFollowLanguage() {
        let original = L10n.language
        defer { L10n.setLanguage(original) }
        L10n.setLanguage(.chinese)
        let cause = PresetOperationError("硬件映射未能保存，恢复点已保留。")
        let failure = PresetAlignmentState.Phase.failed("恢复失败：\(error: cause)")
        let notice = ConsoleNotice(level: .warning, message: "未能核对预设编号，显示未知：\(error: MIDIStartupError.noReply)")
        guard case let .failed(message) = failure else { return XCTFail("Missing retained failure") }
        XCTAssertTrue(L10n.text(message).contains("硬件映射未能保存"))
        L10n.setLanguage(.english)
        XCTAssertTrue(L10n.text(message).contains("hardware map"))
        XCTAssertFalse(L10n.text(message).contains("硬件映射"))
        XCTAssertTrue(notice.text.contains("startup"))
        XCTAssertFalse(notice.text.contains("未确认"))
        L10n.setLanguage(.chinese)
        XCTAssertTrue(L10n.text(message).contains("硬件映射未能保存"))
        XCTAssertTrue(notice.text.contains("未确认"))
    }
}
