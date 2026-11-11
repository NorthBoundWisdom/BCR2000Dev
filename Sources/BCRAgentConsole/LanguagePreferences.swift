import BCRAgentCore
import Foundation

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
