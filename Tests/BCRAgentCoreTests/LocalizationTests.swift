import Foundation
import XCTest
@testable import BCRAgentCore

final class LocalizationTests: XCTestCase {
    func testSystemPreferenceOrderAndFallback() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ZH_HK"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-CN"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ja", "zh-Hans"]), .chinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.chinese.resolved(preferredLanguages: ["en"]), .chinese)
    }

    func testTranslationAndInterpolationDoNotTranslateUserContent() {
        XCTAssertEqual(L10n.text("参数", language: .english), "Parameters")
        XCTAssertEqual(L10n.text("参数", language: .chinese), "参数")
        let userName = "我的 {1} 100% \\\" custom"
        XCTAssertEqual(L10n.text("参数“\(userName)”已更新。", language: .english), "Parameter “\(userName)” updated.")
        XCTAssertEqual(L10n.text("参数“\(userName)”已更新。", language: .chinese), "参数“\(userName)”已更新。")
        XCTAssertEqual(L10n.render("{1} then {0}", arguments: ["{1}", "second"]), "second then {1}")
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
