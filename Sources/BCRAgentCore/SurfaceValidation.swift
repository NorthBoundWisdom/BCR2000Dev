import Foundation

public struct SurfaceValidationIssue: Equatable, Sendable {
    public enum Code: String, Equatable, Sendable {
        case unsupportedVersion, emptyName, invalidParameter, duplicateParameter, duplicateAssignment
        case unknownParameter, encoderTrigger, invalidAgentSlot, unknownGroup
        case duplicateControlBinding, duplicateMIDIBinding, encoderMessageKind
    }
    public let code: Code
    public let subject: String
    public let detail: String

    public init(_ code: Code, subject: String, detail: String) {
        self.code = code
        self.subject = subject
        self.detail = detail
    }
}

public struct SurfaceValidationError: Error, LocalizedError, Equatable, Sendable {
    public let issues: [SurfaceValidationIssue]
    public var errorDescription: String? { issues.map(\.detail).joined(separator: "\n") }
    public init(_ issues: [SurfaceValidationIssue]) { self.issues = issues }
}

public extension SurfaceConfiguration {
    func validate() throws {
        var issues: [SurfaceValidationIssue] = []
        if !(1...Self.currentVersion).contains(version) {
            issues.append(.init(.unsupportedVersion, subject: String(version), detail: "不支持功能配置版本 \(version)"))
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(.emptyName, subject: name, detail: "配置名称不能为空"))
        }
        var identifiers = Set<ParameterID>()
        for parameter in parameters {
            if !identifiers.insert(parameter.id).inserted {
                issues.append(.init(.duplicateParameter, subject: parameter.id.rawValue, detail: "参数 ID 重复：\(parameter.id)"))
            }
            do {
                try parameter.validate()
                if !(parameter.minimum...parameter.maximum).contains(parameter.defaultValue) {
                    issues.append(.init(.invalidParameter, subject: parameter.id.rawValue, detail: "\(parameter.id)：默认值不在参数范围内"))
                }
            } catch {
                issues.append(.init(.invalidParameter, subject: parameter.id.rawValue, detail: "\(parameter.id)：\(error.localizedDescription)"))
            }
        }
        var controls = Set<BCRControlID>()
        for assignment in assignments {
            let label = assignment.control.shortName
            if !controls.insert(assignment.control).inserted {
                issues.append(.init(.duplicateAssignment, subject: label, detail: "控件分配重复：\(label)"))
            }
            if assignment.control.isContinuous, assignment.target.isTrigger {
                issues.append(.init(.encoderTrigger, subject: label, detail: "\(label)：触发功能只能分配给按键"))
            }
            switch assignment.target {
            case let .parameter(id):
                if !identifiers.contains(id) {
                    issues.append(.init(.unknownParameter, subject: id.rawValue, detail: "\(label)：未知参数 \(id)"))
                }
            case let .agentPrimaryAction(slot):
                if !(1...8).contains(slot.rawValue) {
                    issues.append(.init(.invalidAgentSlot, subject: label, detail: "\(label)：Agent 槽位必须是 1–8"))
                }
            case let .resetGroup(group):
                if !parameterGroups.contains(group) {
                    issues.append(.init(.unknownGroup, subject: group, detail: "\(label)：未知参数组 \(group)"))
                }
            }
        }
        if !issues.isEmpty { throw SurfaceValidationError(issues) }
    }

    func migrated() throws -> SurfaceConfiguration {
        try validate()
        var result = self
        result.version = Self.currentVersion
        return result
    }
}

public extension HardwareMap {
    func validate() throws {
        var issues: [SurfaceValidationIssue] = []
        if version != Self.currentVersion {
            issues.append(.init(.unsupportedVersion, subject: String(version), detail: "不支持硬件映射版本 \(version)，需要重新学习"))
        }
        var controls = Set<BCRControlID>()
        var identities = Set<MIDIControlID>()
        for entry in entries {
            if !controls.insert(entry.control).inserted {
                issues.append(.init(.duplicateControlBinding, subject: entry.control.shortName, detail: "物理控件重复绑定：\(entry.control.shortName)"))
            }
            if !identities.insert(entry.midi).inserted {
                issues.append(.init(.duplicateMIDIBinding, subject: entry.midi.description, detail: "MIDI 身份重复：\(entry.midi)"))
            }
            if entry.control.isContinuous, entry.midi.kind != .controlChange {
                issues.append(.init(.encoderMessageKind, subject: entry.control.shortName, detail: "\(entry.control.shortName)：编码器只能绑定 CC"))
            }
        }
        if !issues.isEmpty { throw SurfaceValidationError(issues) }
    }
}
