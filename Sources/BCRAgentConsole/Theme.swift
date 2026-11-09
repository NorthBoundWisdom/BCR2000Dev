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
    case .waitingApproval: "批准"
    case .queued, .running: "中断"
    case .idle, .completed, .interrupted, .error: "启动"
    }
}

struct PanelStyle: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke)
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
