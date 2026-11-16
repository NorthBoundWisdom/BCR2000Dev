import BCRFoundation
import BCRSurfaceDomain
import SwiftUI

struct ParameterColorPicker: View {
    @ObservedObject var model: ConsoleViewModel
    let definition: ParameterDefinition
    var body: some View {
        HStack {
            Text(L10n.text("颜色标签")).frame(width: Theme.fieldLabelWidth, alignment: .leading)
            OffscreenSafeMenu(id: "parameterColor") {
                Button(L10n.text("无颜色")) { select(nil) }
                    .accessibilityIdentifier("parameter.color.none")
                ForEach(ParameterColor.allCases, id: \.self) { color in
                    Button { select(color) } label: {
                        Label(color.title, systemImage: definition.color == color ? "checkmark" : "tag.fill")
                    }
                    .accessibilityIdentifier("parameter.color.\(color.rawValue)")
                }
            } label: {
                Label(definition.color?.title ?? L10n.text("无颜色"), systemImage: "tag.fill")
                    .foregroundStyle(definition.color.map(Theme.tag) ?? .secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("parameter.color")
        }
    }

    private func select(_ color: ParameterColor?) {
        OffscreenInteractionPanel.dismiss(id: "parameterColor")
        model.setParameterColor(color, for: definition.id)
    }
}
