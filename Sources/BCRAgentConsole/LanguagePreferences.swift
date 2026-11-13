import BCRAgentCore
import Foundation
import Combine

// Persistence belongs to the app; Core only resolves language identifiers and messages.
extension AppLanguage {
    static func saved(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "system") ?? .system
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        // App-scoped AppleLanguages also selects native menus and AppKit dialogs on next launch.
        // Never change the global domain or replace the user's system language order.
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// App-owned preference persistence and system-language observation. The console model and
/// device/Agent sessions are independent of this object and are never recreated on a switch.
@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings(initialSelection:
        CommandLine.arguments.contains("--startup-smoke") ? .system : nil)
    private let defaults: UserDefaults
    private let preferredLanguages: @MainActor () -> [String]

    @Published var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            selection.save(in: defaults)
            apply()
        }
    }

    var language: AppLanguage { L10n.language }

    init(defaults: UserDefaults = .standard, initialSelection: AppLanguage? = nil,
         preferredLanguages: @escaping @MainActor () -> [String] = LanguageSettings.systemLanguages)
    {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        selection = initialSelection ?? AppLanguage.saved(in: defaults)
        apply()
    }

    func refreshSystemLanguage() {
        guard selection == .system else { return }
        objectWillChange.send()
        apply()
    }

    private func apply() {
        L10n.setLanguage(selection, preferredLanguages: preferredLanguages())
    }

    /// Ignore a prior app-specific AppleLanguages override when switching back to System.
    /// Explicit launch arguments remain useful for isolated bilingual startup/acceptance.
    private static func systemLanguages() -> [String] {
        if CommandLine.arguments.contains("-AppleLanguages") { return Locale.preferredLanguages }
        let defaults = UserDefaults.standard
        if let arguments = defaults
            .volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] as? [String]
        {
            return arguments
        }
        return defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
    }
}
