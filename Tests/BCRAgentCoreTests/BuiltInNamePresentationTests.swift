import BCRAgentCore
import Foundation
import XCTest

final class BuiltInNamePresentationTests: XCTestCase {
    func testEveryBuiltInNameTranslatesInBothDirections() {
        let names: [LocalizedMessage] = [
            "J1 底座旋转", "J2 肩部", "J3 肘部", "J4 腕部俯仰", "J5 腕部旋转", "J6 末端旋转",
            "夹爪开合", "运动速度", "使能", "机械臂", "通用", "机械臂示例", "默认配置"
        ] + (1 ... 8).map { "参数 \($0)" }
        for message in names {
            let chinese = L10n.text(message, language: .chinese)
            let english = L10n.text(message, language: .english)
            XCTAssertNotEqual(chinese, english)
            XCTAssertEqual(BuiltInNamePresentation.displayName(chinese, language: .english), english)
            XCTAssertEqual(BuiltInNamePresentation.displayName(english, language: .chinese), chinese)
        }
    }

    func testCustomAndUnknownNamesRemainVerbatim() {
        for name in ["我的机械臂", "J1 底座旋转 custom", "Robot Arm 2", "参数 9", " 参数 1", "unknown", ""] {
            for language in [AppLanguage.chinese, .english] {
                XCTAssertEqual(BuiltInNamePresentation.displayName(name, language: language), name)
            }
        }
    }

    /// Review finding: in the English UI the group field shows "Robot Arm" for the stored "机械臂".
    /// Typing a character and deleting it wrote "Robot Arm" back, splitting the parameter from its
    /// group and from the reset button that references the stored string.
    func testNoOpEditOfATranslatedFieldKeepsTheStoredSpelling() {
        var saved = "机械臂"
        let shown = { BuiltInNamePresentation.displayName(saved, language: .english) }
        let type = { (text: String) in
            saved = BuiltInNamePresentation.editedName(text, replacing: saved, language: .english)
        }
        type(shown() + "x")
        XCTAssertEqual(saved, "Robot Armx")
        type("Robot Arm")
        // The user really typed the English built-in over a custom name: that is a real edit.
        XCTAssertEqual(saved, "Robot Arm")

        saved = "机械臂"
        type(shown())
        XCTAssertEqual(saved, "机械臂", "committing unchanged text must not rewrite the stored name")
        type("My Arm")
        XCTAssertEqual(saved, "My Arm")
        // In the stored language nothing is translated, so every edit is taken literally.
        XCTAssertEqual(BuiltInNamePresentation.editedName("机械臂", replacing: "机械臂", language: .chinese), "机械臂")
        XCTAssertEqual(BuiltInNamePresentation.editedName("手臂", replacing: "机械臂", language: .chinese), "手臂")
    }

    func testSameConfigurationCanDisplayBothLanguagesWithoutChangingEncodedValuesOrGroupReferences() throws {
        let configuration = SurfaceConfiguration(
            name: "机械臂示例",
            parameters: [.init(id: "arm.j1", name: "J1 底座旋转", group: "机械臂", minimum: 0, maximum: 100)],
            assignments: [.init(control: .button(row: 2, 8), target: .resetGroup("机械臂"))]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(configuration)
        let names = [configuration.name, configuration.parameters[0].name, configuration.parameters[0].group]
        let chinese = names.map { BuiltInNamePresentation.displayName($0, language: .chinese) }
        let english = names.map { BuiltInNamePresentation.displayName($0, language: .english) }
        XCTAssertEqual(chinese, names)
        XCTAssertEqual(english, ["Robot Arm Example", "J1 Base Rotation", "Robot Arm"])
        XCTAssertEqual(try encoder.encode(configuration), before)
        XCTAssertEqual(configuration.controls(targeting: .resetGroup("机械臂")), [.button(row: 2, 8)])
    }
}
