import BCRFoundation
import SwiftUI

struct ParameterHistoryButtons: View {
    @ObservedObject var model: ConsoleViewModel
    var body: some View {
        HStack {
            Button { model.undo() } label: { Label(L10n.text("撤销数值变化"), systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .accessibilityIdentifier("parameters.undo")
            Button { model.redo() } label: { Label(L10n.text("重做数值变化"), systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .accessibilityIdentifier("parameters.redo")
            Spacer()
        }
        .controlSize(.small)
    }
}
