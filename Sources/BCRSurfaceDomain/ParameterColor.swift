import BCRFoundation
import Foundation

/// Software label only. These names match the sibling host's durable color vocabulary.
public enum ParameterColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink
    public var title: String {
        switch self {
        case .red: L10n.text("红色")
        case .orange: L10n.text("橙色")
        case .yellow: L10n.text("黄色")
        case .green: L10n.text("绿色")
        case .teal: L10n.text("青色")
        case .blue: L10n.text("蓝色")
        case .purple: L10n.text("紫色")
        case .pink: L10n.text("粉色")
        }
    }
}
