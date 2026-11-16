import SwiftUI

/// Explicit theme colors keep evidence controls readable in detached/offscreen hosts too.
struct EvidenceButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                configuration.isPressed ? Theme.chassisBottom : Theme.chassisTop,
                in: RoundedRectangle(cornerRadius: 5)
            )
    }
}
