import Foundation

/// Persisted language choice. The raw values are stable preferences, never translated labels.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "appLanguage"

    /// Select the first supported language in the system preference order; otherwise use English.
    public func resolved(preferredLanguages: [String]) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            switch identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
            case "zh": return .chinese
            case "en": return .english
            default: continue
            }
        }
        return .english
    }
}

/// A value-type message keeps interpolation arguments out of the lookup key.
/// Numbered placeholders allow translations to reorder values without printf type hazards.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    public let key: String
    public let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) { key += literal }

        public mutating func appendInterpolation(_ value: some Any) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

public enum L10n {
    /// Freeze the language for this process. Restart applies a new preference consistently to
    /// stored notices, native menus, background errors, and SwiftUI without resetting sessions.
    public static let language = AppLanguage.system.resolved(preferredLanguages: Locale.preferredLanguages)

    private static let englishBundle = localizedBundle(.english)
    private static let chineseBundle = localizedBundle(.chinese)

    static func localizedBundle(_ language: AppLanguage) -> Bundle {
        guard let url = ProviderResources.bundle.url(forResource: language.rawValue, withExtension: "lproj"),
              let bundle = Bundle(url: url)
        else { preconditionFailure("Missing bundled localization: \(language.rawValue)") }
        return bundle
    }

    public static func text(_ message: LocalizedMessage, language: AppLanguage = language) -> String {
        let resolved = language.resolved(preferredLanguages: Locale.preferredLanguages)
        let bundle = resolved == .chinese ? chineseBundle : englishBundle
        let template = bundle.localizedString(forKey: message.key, value: message.key, table: "Localizable")
        return render(template, arguments: message.arguments)
    }

    /// Substitute only tokens in the template, never tokens contained in user-supplied arguments.
    static func render(_ template: String, arguments: [String]) -> String {
        var result = ""
        var cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: cursor) ..< end]),
               arguments.indices.contains(index)
            {
                result += arguments[index]
                cursor = template.index(after: end)
            } else {
                result.append(template[cursor])
                cursor = template.index(after: cursor)
            }
        }
        return result
    }
}
