import Foundation

public struct BulkAssignmentChange: Equatable, Sendable {
    public let previous: ControlAssignment?
    public let proposed: ControlAssignment
}

public struct BulkAssignmentPlan: Equatable, Sendable {
    public let base: SurfaceConfiguration
    public let changes: [BulkAssignmentChange]
    public let skippedParameters: Int

    public init(configuration: SurfaceConfiguration, section: BCRSection, row: Int, group: String) throws {
        try configuration.validate()
        guard section.rowRange.contains(row) else {
            throw ControlAssignmentPlanError.invalidRow
        }
        let parameters = configuration.parameters.filter { $0.group == group }
        guard !parameters.isEmpty else { throw ControlAssignmentPlanError.emptyGroup }
        let controls = BCRLayout.controls(in: section).filter { $0.row == row }
        base = configuration
        changes = zip(controls, parameters).map { control, parameter in
            BulkAssignmentChange(previous: configuration.assignment(for: control),
                                 proposed: ControlAssignment(control: control, target: .parameter(parameter.id)))
        }
        skippedParameters = max(0, parameters.count - controls.count)
    }
}

public enum ControlAssignmentPlanError: Error, Equatable, LocalizedError, Sendable {
    case invalidRow, emptyGroup, stalePreview
    public var errorDescription: String? {
        switch self {
        case .invalidRow: L10n.text("所选控件行无效")
        case .emptyGroup: L10n.text("所选分组没有参数")
        case .stalePreview: L10n.text("配置已在其他位置修改，请重新预览后确认")
        }
    }
}

public extension SurfaceEngine {
    mutating func apply(_ plan: BulkAssignmentPlan, at now: Date = .now) throws -> [SurfaceEffect] {
        guard configuration == plan.base else { throw ControlAssignmentPlanError.stalePreview }
        var candidate = self
        var effects: [SurfaceEffect] = []
        for change in plan.changes { effects += try candidate.assign(change.proposed, at: now) }
        self = candidate
        return effects
    }
}
