import BCRFoundation
import BCRCodexAdapter
import BCRSurfaceDomain
import BCRExamples
import BCRConfigurationAdapter
import BCRMCPAdapter
import BCRHTTPTransport
import BCRCoreMIDIDriver
import BCRPersistenceAdapter
import SwiftUI

struct TriggerParameterEditor: View {
    @ObservedObject var model: ConsoleViewModel
    let control: BCRControlID
    let target: ControlTarget
    @State private var cycleText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let id = target.parameterID {
                FieldRow(L10n.text("参数")) {
                    Picker(L10n.text("参数"), selection: Binding(get: { id }, set: { changeParameter($0) })) {
                        ForEach(model.configuration.parameters) {
                            Text(BuiltInNamePresentation.displayName($0.name)).tag($0.id)
                        }
                    }.accessibilityIdentifier("trigger.parameter.editor.parameters.\(control.accessibilityID)")
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
            FieldRow(L10n.text("步进量")) {
                TextField(L10n.text("步进量"), value: Binding(get: { step }, set: {
                    update(.stepParameter(id: id, step: $0, wraps: wraps))
                }), format: .number)
                    .accessibilityIdentifier("trigger.parameter.editor.step.amount.\(control.accessibilityID)")
                    .textFieldStyle(.roundedBorder)
            }
            FieldIndent {
                Toggle(L10n.text("越界循环到另一端"), isOn: Binding(get: { wraps }, set: {
                    update(.stepParameter(id: id, step: step, wraps: $0))
                }))
                .accessibilityIdentifier("trigger.parameter.editor.wrap.at.range.boundary.\(control.accessibilityID)")
            }
        case let .setParameter(_, value):
            FieldRow(L10n.text("指定值")) {
                TextField(L10n.text("指定值"), value: Binding(get: { value }, set: {
                    update(.setParameter(id: id, value: $0))
                }), format: .number)
                    .accessibilityIdentifier("trigger.parameter.editor.value.\(control.accessibilityID)")
                    .textFieldStyle(.roundedBorder)
            }
        case .cycleParameter:
            FieldRow(L10n.text("循环预设值")) {
                TextField(L10n.text("循环值（逗号分隔）"), text: $cycleText)
                    .accessibilityIdentifier(
                        "trigger.parameter.editor.cycle.values.comma.separated.\(control.accessibilityID)"
                    )
                    .textFieldStyle(.roundedBorder)
            }
            FieldIndent {
                Button(L10n.text("应用循环值")) { model.setCycleValues(cycleText, parameter: id, for: control) }
                    .accessibilityIdentifier("trigger.parameter.editor.apply.cycle.values.\(control.accessibilityID)")
            }
            FieldNote(L10n.text("按给定顺序循环；当前值不在列表时从第一项开始。"))
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
