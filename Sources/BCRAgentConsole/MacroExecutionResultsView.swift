import BCRFoundation
import BCRSurfaceDomain
import SwiftUI

struct MacroExecutionResultsView: View {
    let execution: MacroExecution
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(execution.name).font(.headline)
            ForEach(execution.steps) { step in
                HStack {
                    Text("#\(step.id + 1)")
                    Label(step.outcome == .applied ? L10n.text("已应用") : L10n.text("已拒绝"),
                          systemImage: step.outcome == .applied ? "checkmark.circle" : "xmark.circle")
                    if let reason = step.reason { Text(L10n.text(reason.localizedMessage)).foregroundStyle(.orange) }
                }
            }
        }
    }
}
