import BCRAgentCore

/// UI-only draft lifecycle; external definition updates never silently discard edited fields.
struct ParameterDraftState: Equatable {
    var value: ParameterDefinition
    private(set) var baseline: ParameterDefinition
    private(set) var conflict: ParameterDefinition?
    var isDirty: Bool { value != baseline }

    init(_ definition: ParameterDefinition) {
        value = definition
        baseline = definition
    }

    mutating func receive(_ definition: ParameterDefinition) {
        if !isDirty || value == definition {
            reload(definition)
        } else if definition == baseline {
            conflict = nil
        } else {
            conflict = definition
        }
    }

    mutating func reload(_ definition: ParameterDefinition) {
        value = definition
        baseline = definition
        conflict = nil
    }

    mutating func keepDraft() {
        guard let conflict else { return }
        baseline = conflict
        self.conflict = nil
    }
}
