import BCRAgentCore
import SwiftUI

enum Theme {
    static let background = Color(red: 0.055, green: 0.06, blue: 0.072)
    static let surface = Color.white.opacity(0.045)
    static let stroke = Color.white.opacity(0.08)
    static let chassisTop = Color(red: 0.16, green: 0.17, blue: 0.19)
    static let chassisBottom = Color(red: 0.09, green: 0.095, blue: 0.11)
    /// The BCR2000's LEDs are red.
    static let led = Color(red: 1.0, green: 0.25, blue: 0.18)
    static let ledOff = Color.white.opacity(0.09)
    static let parameter = Color(red: 0.25, green: 0.82, blue: 0.78)
    static let trigger = Color.orange
    static let selection = Color(red: 0.42, green: 0.62, blue: 1.0)
    static let learn = Color.yellow
    /// Nested cards inside a panel.
    static let inset = Color.black.opacity(0.15)

    static let panelRadius: CGFloat = 12
    static let insetRadius: CGFloat = 9
    /// Height of the window's title strip; the traffic lights occupy its leading edge.
    static let titleStripHeight: CGFloat = 28
    static let trafficLightInset: CGFloat = 78
    /// Shared label column so every inspector control starts on the same vertical line.
    static let fieldLabelWidth: CGFloat = 96
}

func stateColor(_ state: AgentRunState) -> Color {
    switch state {
    case .idle: .gray
    case .queued: .blue
    case .running: .green
    case .waitingApproval: .orange
    case .completed: .cyan
    case .interrupted: .yellow
    case .error: .red
    }
}

func primaryActionTitle(_ state: AgentRunState) -> String {
    switch state {
    case .waitingApproval: L10n.text("批准")
    case .queued, .running: L10n.text("中断")
    case .idle, .completed, .interrupted, .error: L10n.text("启动")
    }
}

struct PanelStyle: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.panelRadius).stroke(Theme.stroke)
            }
    }
}

extension View {
    func panelStyle(padding: CGFloat = 14) -> some View {
        modifier(PanelStyle(padding: padding))
    }
}

struct SectionTitle: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }
}

extension View {
    /// Card nested inside a panel (parameter groups, agent slots).
    func insetCard(padding: CGFloat = 10) -> some View {
        self.padding(padding)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.insetRadius))
    }
}

/// One inspector form row: a fixed label column followed by the control.
/// The label stays attached to the control for accessibility even though it is drawn separately.
struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Theme.fieldLabelWidth, alignment: .leading)
                .accessibilityHidden(true)
            content()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A row without a label that still starts at the control column (checkboxes, row actions).
struct FieldIndent<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Color.clear.frame(width: Theme.fieldLabelWidth, height: 1)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Explanatory text under a group of fields.
struct FieldNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Compact header status: tinted icon, title and an optional detail that truncates first.
struct StatusChip: View {
    let title: String
    let icon: String
    let tint: Color
    var detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(title)
                .fontWeight(.medium)
                .lineLimit(1)
                .fixedSize()
            if let detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading)
                    .layoutPriority(-1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.surface, in: Capsule())
        .overlay { Capsule().stroke(tint.opacity(0.28)) }
        .contentShape(Capsule())
    }
}
