import BCRFoundation
import BCRSurfaceDomain
import BCRExamples
import Foundation

/// Distinct launch evidence for a rendered native window and an isolated value-only check.
struct NativeStartupEvidence: Encodable {
    let type = "bcr.native_startup"
    let mode: String
    let hardwareAccessed: Bool
    let windowCreated: Bool
    let firstFramePresented: Bool
    let first_frame: Bool // Retained for existing native-startup consumers.
    let icon: Bool
    let clientVersion: String
    let language: String
    let settings: String

    static func gui() -> Self {
        .init(mode: "gui", hardwareAccessed: false, windowCreated: true,
              firstFramePresented: true, first_frame: true, icon: true,
              clientVersion: AppBuildVersion.current, language: L10n.language.rawValue, settings: L10n.text("设置"))
    }

    static func headless() throws -> Self {
        // Values only: no ConsoleViewModel, device, persistent store, MCP or output adapter.
        let configuration = ConfigurationPreset.starter.makeConfiguration()
        try configuration.validate()
        var engine = SurfaceEngine(hardwareMap: .mockPreset(), configuration: configuration)
        _ = engine.setParameter("general.1", to: 42, at: Date(timeIntervalSince1970: 0))
        guard engine.value(of: "general.1") == 42 else { throw CocoaError(.coderInvalidValue) }
        return .init(mode: "headless", hardwareAccessed: false, windowCreated: false,
                     firstFramePresented: false, first_frame: false,
                     icon: Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil,
                     clientVersion: AppBuildVersion.current, language: L10n.language.rawValue,
                     settings: L10n.text("设置"))
    }

    func emit() throws {
        var data = try JSONEncoder().encode(self)
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
