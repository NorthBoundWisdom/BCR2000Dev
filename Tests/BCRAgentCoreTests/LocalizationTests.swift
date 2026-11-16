@testable import BCRFoundation
@testable import BCRCodexAdapter
@testable import BCRSurfaceDomain
@testable import BCRExamples
@testable import BCRConfigurationAdapter
@testable import BCRMCPAdapter
@testable import BCRHTTPTransport
@testable import BCRCoreMIDIDriver
@testable import BCRPersistenceAdapter
import Foundation
import Observation
import XCTest

final class LocalizationTests: XCTestCase {
    func testExplicitLanguageLookupAcceptsSwiftPMLowercaseDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appending(path: "zh-hans.lproj")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try Data("\"probe\" = \"中文\";".utf8).write(to: catalog.appending(path: "Localizable.strings"))
        let resources = try XCTUnwrap(Bundle(url: root))
        let localized = L10n.localizedBundle(.chinese, resources: resources)
        XCTAssertEqual(localized.localizedString(forKey: "probe", value: nil, table: nil), "中文")
    }

    func testSystemPreferenceOrderAndFallback() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ZH_HK"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-CN"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ja", "zh-Hans"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-MO"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-HK"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-SG"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.chinese.resolved(preferredLanguages: ["en"]), .chinese)
    }

    func testTraditionalLookupAcceptsSwiftPMLowercaseDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appending(path: "zh-hant.lproj")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try Data("\"probe\" = \"繁體中文\";".utf8).write(to: catalog.appending(path: "Localizable.strings"))
        let resources = try XCTUnwrap(Bundle(url: root))
        let localized = L10n.localizedBundle(.traditionalChinese, resources: resources)
        XCTAssertEqual(localized.localizedString(forKey: "probe", value: nil, table: nil), "繁體中文")
    }

    func testTranslationAndInterpolationDoNotTranslateUserContent() {
        XCTAssertEqual(L10n.text("参数", language: .english), "Parameters")
        XCTAssertEqual(L10n.text("参数", language: .chinese), "参数")
        XCTAssertEqual(L10n.text("参数", language: .traditionalChinese), "參數")
        let userName = "我的 {1} 100% \\\" custom"
        XCTAssertEqual(L10n.text("参数“\(userName)”已更新。", language: .english), "Parameter “\(userName)” updated.")
        XCTAssertEqual(L10n.text("参数“\(userName)”已更新。", language: .chinese), "参数“\(userName)”已更新。")
        XCTAssertEqual(L10n.render("{1} then {0}", arguments: ["{1}", "second"]), "second then {1}")
    }

    @MainActor
    func testRuntimeLanguageInvalidatesTrackedTextWithoutRecreatingTheReader() {
        let original = L10n.language
        defer { L10n.setLanguage(original) }
        L10n.setLanguage(.chinese)
        let changed = XCTestExpectation(description: "localized text observes language")
        let text = withObservationTracking { L10n.text("参数") } onChange: { changed.fulfill() }
        XCTAssertEqual(text, "参数")
        L10n.setLanguage(.english)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1), .completed)
        XCTAssertEqual(L10n.text("参数"), "Parameters")
        XCTAssertEqual(L10n.text("参数", language: .chinese), "参数")
        XCTAssertEqual(L10n.text("参数", language: .traditionalChinese), "參數")
    }

    func testShippedCatalogsHaveCompleteMatchingTranslationsAndPlaceholders() throws {
        func catalog(_ language: AppLanguage) throws -> [String: String] {
            let url = try XCTUnwrap(L10n.localizedBundle(language).url(
                forResource: "Localizable",
                withExtension: "strings"
            ))
            return try XCTUnwrap(PropertyListSerialization
                .propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let chinese = try catalog(.chinese)
        let english = try catalog(.english)
        let traditional = try catalog(.traditionalChinese)
        XCTAssertEqual(Set(traditional.keys), Set(english.keys))
        XCTAssertGreaterThan(english.count, 600)
        XCTAssertEqual(Set(chinese.keys), Set(english.keys))
        let placeholders = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func tokens(_ value: String) -> [String] {
            placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .map { (value as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, translation) in english {
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertNotEqual(translation, key, key)
            XCTAssertEqual(chinese[key], key)
            XCTAssertEqual(tokens(translation), tokens(key), key)
            let traditionalText = try XCTUnwrap(traditional[key], key)
            XCTAssertFalse(traditionalText.isEmpty, key)
            XCTAssertEqual(tokens(traditionalText), tokens(key), key)
        }
    }

    func testSavedNamesAndGroupBindingsRemainVerbatim() throws {
        let original = SurfaceConfiguration(
            name: "我的配置 Custom",
            parameters: [.init(id: "custom.1", name: "自定义名称 My Name", group: "原分组", minimum: 0, maximum: 1)],
            assignments: [.init(control: .button(row: 2, 8), target: .resetGroup("原分组"))]
        )
        let restored = try JSONDecoder().decode(SurfaceConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.controls(targeting: .resetGroup("原分组")), [.button(row: 2, 8)])
    }
}

extension LocalizationTests {
    func testNestedMessagesLocalizeWithoutTranslatingVerbatimArguments() {
        let custom = "用户 {0} custom"
        let inner: LocalizedMessage = "参数“\(custom)”已更新。"
        let outer: LocalizedMessage = "\(inner)"
        XCTAssertEqual(L10n.text(outer, language: .english), "Parameter “\(custom)” updated.")
        XCTAssertEqual(L10n.text(outer, language: .chinese), "参数“\(custom)”已更新。")
    }
}

extension LocalizationTests {
    @MainActor
    func testRetainedPresetParserCauseKeepsItsMessageKey() throws {
        let original = L10n.language
        defer { L10n.setLanguage(original) }
        L10n.setLanguage(.chinese)
        var retained: LocalizedMessage?
        do { _ = try BCRPresetAlignment.canonicalLines(of: Data([0])) }
        catch { retained = "读取设备预设失败：\(error: error)" }
        let message = try XCTUnwrap(retained)
        XCTAssertTrue(L10n.text(message).contains("SysEx 帧不完整"))
        L10n.setLanguage(.english)
        let translated = L10n.text(message)
        XCTAssertTrue(translated.contains("Incomplete SysEx"), translated)
        XCTAssertFalse(translated.contains("SysEx 帧不完整"))
    }
}
