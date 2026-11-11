import BCRAgentCore
import SwiftUI

struct TriggerParameterEditor: View {
    @ObservedObject var model: ConsoleViewModel
    let control: BCRControlID
    let target: ControlTarget
    @State private var cycleText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = target.parameterID {
                Picker(L10n.text("参数"), selection: Binding(get: { id }, set: { changeParameter($0) })) {
                    ForEach(model.configuration.parameters) { Text($0.name).tag($0.id) }
                }
                fields(id)
            }
        }
        .onAppear { refreshCycleText() }
        .onChange(of: target) { _, _ in refreshCycleText() }
    }

    @ViewBuilder
    private func fields(_ id: ParameterID) -> some View {
        switch target {
        case let .stepParameter(_, step, wraps):
            TextField(L10n.text("步进量"), value: Binding(get: { step }, set: {
                update(.stepParameter(id: id, step: $0, wraps: wraps))
            }), format: .number)
            Toggle(L10n.text("越界循环到另一端"), isOn: Binding(get: { wraps }, set: {
                update(.stepParameter(id: id, step: step, wraps: $0))
            }))
        case let .setParameter(_, value):
            TextField(L10n.text("指定值"), value: Binding(get: { value }, set: {
                update(.setParameter(id: id, value: $0))
            }), format: .number)
        case .cycleParameter:
            TextField(L10n.text("循环值（逗号分隔）"), text: $cycleText)
            Button(L10n.text("应用循环值")) { model.setCycleValues(cycleText, parameter: id, for: control) }
            Text(L10n.text("按给定顺序循环；当前值不在列表时从第一项开始。")).font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    private func changeParameter(_ id: ParameterID) {
        guard let definition = model.configuration.parameter(id) else { return }
        switch target {
        case let .stepParameter(_, step, wraps): update(.stepParameter(id: id, step: step, wraps: wraps))
        case .setParameter: update(.setParameter(id: id, value: definition.defaultValue))
        case .cycleParameter:
            var seen = Set<Double>()
            let values = [definition.minimum, definition.clamp(definition.defaultValue), definition.maximum]
                .filter { seen.insert($0).inserted }
            update(.cycleParameter(id: id, values: values))
        default: break
        }
    }

    private func refreshCycleText() {
        if case let .cycleParameter(_, values) = target { cycleText = values.map { String($0) }.joined(separator: ", ")
        }
    }

    private func update(_ target: ControlTarget) {
        var next = model.configuration.assignment(for: control) ?? ControlAssignment(control: control, target: target)
        next.target = target
        model.setAssignment(next, for: control)
    }
}
