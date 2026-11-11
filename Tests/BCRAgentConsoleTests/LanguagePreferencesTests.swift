import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

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
}
