import Foundation

enum WorkspaceTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case parameters, arm, agents, monitor, output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parameters: "参数"
        case .arm: "机械臂预览"
        case .agents: "Agent"
        case .monitor: "MIDI 监视"
        case .output: "输出"
        }
    }

    var systemImage: String {
        switch self {
        case .parameters: "slider.horizontal.3"
        case .arm: "point.3.connected.trianglepath.dotted"
        case .agents: "square.grid.2x2"
        case .monitor: "waveform.path"
        case .output: "arrow.up.forward.circle"
        }
    }

    /// Specialist panels stay out of the workspace until the user enables them from the panel menu.
    var isOptional: Bool {
        switch self {
        case .arm, .output: true
        case .parameters, .agents, .monitor: false
        }
    }

    var optionalSummary: String? {
        switch self {
        case .arm: "示例机械臂的侧视 / 俯视姿态示意"
        case .output: "OSC 目标、受限输出与实际回传读数"
        case .parameters, .agents, .monitor: nil
        }
    }

    static let optional = allCases.filter(\.isOptional)
}

enum WorkspacePanelSettingsError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case notOptional(String)
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): "面板设置版本 \(version) 不受支持"
        case let .notOptional(name): "“\(name)”不是可选面板"
        case let .duplicate(name): "面板“\(name)”重复出现"
        }
    }
}

/// Which specialist workspace panels the user has switched on. Core panels are always shown.
struct WorkspacePanelSettings: Codable, Equatable, Sendable {
    static let currentVersion = 1

    private(set) var version = WorkspacePanelSettings.currentVersion
    private(set) var enabled: [WorkspaceTab] = []

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw WorkspacePanelSettingsError.unsupportedVersion(version) }
        // Unknown panel names fail decoding instead of being dropped.
        let panels = try container.decode([WorkspaceTab].self, forKey: .enabled)
        for panel in panels {
            guard panel.isOptional else { throw WorkspacePanelSettingsError.notOptional(panel.title) }
            guard !enabled.contains(panel) else { throw WorkspacePanelSettingsError.duplicate(panel.title) }
            enabled.append(panel)
        }
        enabled = Self.ordered(enabled)
    }

    func isEnabled(_ panel: WorkspaceTab) -> Bool {
        enabled.contains(panel)
    }

    mutating func set(_ panel: WorkspaceTab, enabled isOn: Bool) throws {
        guard panel.isOptional else { throw WorkspacePanelSettingsError.notOptional(panel.title) }
        var panels = enabled.filter { $0 != panel }
        if isOn { panels.append(panel) }
        enabled = Self.ordered(panels)
    }

    /// Tabs in display order. The output readout is also shown while output is running, so a
    /// live safety gate is never hidden behind a menu.
    func visibleTabs(outputActive: Bool) -> [WorkspaceTab] {
        WorkspaceTab.allCases.filter { tab in
            !tab.isOptional || isEnabled(tab) || (tab == .output && outputActive)
        }
    }

    /// The tab to display for a remembered selection; hidden selections fall back to parameters.
    func resolved(_ selection: WorkspaceTab, outputActive: Bool) -> WorkspaceTab {
        visibleTabs(outputActive: outputActive).contains(selection) ? selection : .parameters
    }

    private static func ordered(_ panels: [WorkspaceTab]) -> [WorkspaceTab] {
        WorkspaceTab.allCases.filter(panels.contains)
    }
}
