import Foundation

/// Packaging writes this metadata from configs/app_build.json plus explicit local/CI overrides.
/// Standalone SwiftPM/test executables have no app version and identify themselves as development.
enum AppBuildVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
