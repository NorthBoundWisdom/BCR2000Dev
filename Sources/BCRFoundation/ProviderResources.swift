import Foundation

public enum ProviderResources {
    private static var adjacent: Bundle? {
        let name = "BCRAgentConsole_BCRFoundation.bundle"
        let candidates = [Bundle.main.resourceURL?.appending(path: name), Bundle.main.bundleURL.appending(path: name)]
        return candidates.compactMap { $0 }.compactMap(Bundle.init(url:)).first
    }

    public static var hasAdjacentBundle: Bool { adjacent != nil }
    public static var origin: String { hasAdjacentBundle ? "embedded" : "swiftpm_development" }
    public static var bundle: Bundle {
        if let adjacent { return adjacent }
        guard ProcessInfo.processInfo.environment["BCR_PROVIDER_PACKAGED"] != "1"
        else { preconditionFailure("The published provider resource bundle is missing") }
        return Bundle.module
    }
}
