import BCRFoundation
import Foundation

public struct SurfaceValidationIssue: Equatable, Sendable {
    public enum Code: String, Equatable, Sendable {
        case unsupportedVersion, emptyName, invalidParameter, duplicateParameter, duplicateAssignment
        case unknownParameter, encoderTrigger, invalidAgentSlot, unknownGroup, invalidFunction
        case invalidEncoderMode, conflictingNRPNChannel, duplicateControlBinding, duplicateMIDIBinding,
             encoderMessageKind
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
        if !(1 ... Self.currentVersion).contains(version) {
            issues.append(.init(
                .unsupportedVersion,
                subject: String(version),
                detail: L10n.text("不支持功能配置版本 \(version)")
            ))
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(.emptyName, subject: name, detail: L10n.text("配置名称不能为空")))
        }
        var identifiers = Set<ParameterID>()
        for parameter in parameters {
            if !identifiers.insert(parameter.id).inserted {
                issues.append(.init(
                    .duplicateParameter,
                    subject: parameter.id.rawValue,
                    detail: L10n.text("参数 ID 重复：\(parameter.id)")
                ))
            }
            do {
                try parameter.validate()
                if !(parameter.minimum ... parameter.maximum).contains(parameter.defaultValue) {
                    issues.append(.init(
                        .invalidParameter,
                        subject: parameter.id.rawValue,
                        detail: L10n.text("\(parameter.id)：默认值不在参数范围内")
                    ))
                }
            } catch {
                issues.append(.init(
                    .invalidParameter,
                    subject: parameter.id.rawValue,
                    detail: "\(parameter.id)：\(error.localizedDescription)"
                ))
            }
        }
        if pages.count > 32 || Set(pages.map(\.id)).count != pages.count ||
            pages
            .contains(where: {
                $0.id.isEmpty || $0.id == SurfaceConfiguration.basePageID || $0.name
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) ||
            (activePageID != nil && !pages.contains(where: { $0.id == activePageID }))
        {
            issues.append(.init(.invalidFunction, subject: name, detail: L10n.text("页面定义无效")))
        }
        if macros.count > 128 || Set(macros.map(\.id)).count != macros.count {
            issues.append(.init(.invalidFunction, subject: name, detail: L10n.text("宏定义无效")))
        }
        for macro in macros {
            var invalid = macro.id.isEmpty || macro.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty || macro.actions.isEmpty || macro.actions.count > 64
            for action in macro.actions {
                switch action {
                case let .set(id, value):
                    invalid = invalid || !value.isFinite || parameter(id)
                        .map { !($0.minimum ... $0.maximum).contains(value) } != false
                case let .step(id, delta):
                    invalid = invalid || !delta.isFinite || delta == 0 || parameter(id)
                        .map { !($0.minimum + delta).isFinite || !($0.maximum + delta).isFinite } != false
                case let .resetGroup(group): invalid = invalid || !parameterGroups.contains(group)
                }
            }
            if invalid { issues.append(.init(.invalidFunction, subject: macro.id, detail: L10n.text("宏定义无效"))) }
        }
        for assignments in allAssignmentSets {
            var controls = Set<BCRControlID>()
            for assignment in assignments {
                let label = assignment.control.shortName
                if !controls.insert(assignment.control).inserted {
                    issues.append(.init(.duplicateAssignment, subject: label, detail: L10n.text("控件分配重复：\(label)")))
                }
                if assignment.control.isContinuous, assignment.target.isTrigger {
                    issues.append(.init(.encoderTrigger, subject: label, detail: L10n.text("\(label)：触发功能只能分配给按键")))
                }
                if let id = assignment.target.parameterID, !identifiers.contains(id) {
                    issues.append(.init(
                        .unknownParameter,
                        subject: id.rawValue,
                        detail: L10n.text("\(label)：未知参数 \(id)")
                    ))
                }
                if !assignment.encoderStep.isFinite || assignment.encoderStep <= 0 {
                    issues.append(.init(.invalidEncoderMode, subject: label, detail: L10n.text("\(label)：相对步长必须为有限正数")))
                }
                if assignment.encoderMode != .absolute {
                    let definition = assignment.target.parameterID.flatMap { parameter($0) }
                    if !assignment.control.isContinuous || assignment.target.isTrigger || definition?
                        .kind != .continuous
                    {
                        issues.append(.init(
                            .invalidEncoderMode,
                            subject: label,
                            detail: L10n.text("\(label)：相对模式只适用于连续参数编码器")
                        ))
                    }
                }
                switch assignment.target {
                case .parameter: break
                case let .switchPage(id):
                    if id != SurfaceConfiguration.basePageID && !pages
                        .contains(where: { $0.id == id })
                    { issues.append(.init(
                        .invalidFunction,
                        subject: id,
                        detail: L10n.text("未知页面")
                    )) }
                case let .runMacro(id):
                    if !macros.contains(where: { $0.id == id }) { issues.append(.init(
                        .invalidFunction,
                        subject: id,
                        detail: L10n.text("未知宏")
                    )) }
                case let .stepParameter(_, step, _):
                    if !step.isFinite || step == 0 {
                        issues.append(.init(
                            .invalidFunction,
                            subject: label,
                            detail: L10n.text("\(label)：步进值必须有限且不为零")
                        ))
                    }
                case let .setParameter(id, value):
                    if !value.isFinite || parameter(id).map({ value < $0.minimum || value > $0.maximum }) == true {
                        issues.append(.init(
                            .invalidFunction,
                            subject: label,
                            detail: L10n.text("\(label)：指定值必须在参数范围内")
                        ))
                    }
                case let .cycleParameter(id, values):
                    let finite = values.allSatisfy(\.isFinite)
                    var invalid = values.isEmpty || values.count > 256 || !finite
                    if let definition = parameter(id) {
                        invalid = invalid || values.contains { $0 < definition.minimum || $0 > definition.maximum }
                        if finite, (try? definition.validate()) != nil {
                            invalid = invalid || Set(values.map(definition.clamp)).count != values.count
                        }
                    }
                    if invalid {
                        issues.append(.init(
                            .invalidFunction,
                            subject: label,
                            detail: L10n.text("\(label)：循环值需为 1–256 个范围内的不同值（吸附后也不可重复）")
                        ))
                    }
                case let .agentPrimaryAction(slot):
                    if !(1 ... 8).contains(slot.rawValue) {
                        issues.append(.init(
                            .invalidAgentSlot,
                            subject: label,
                            detail: L10n.text("\(label)：Agent 槽位必须是 1–8")
                        ))
                    }
                case let .resetGroup(group):
                    if !parameterGroups.contains(group) {
                        issues.append(.init(
                            .unknownGroup,
                            subject: group,
                            detail: L10n.text("\(label)：未知参数组 \(group)")
                        ))
                    }
                }
            }
        }
        if !issues.isEmpty { throw SurfaceValidationError(issues) }
    }

    func migrated() throws -> SurfaceConfiguration {
        try validate()
        var result = self
        result.version = Self.currentVersion
        try result.selectPage(nil)
        return result
    }
}

public extension HardwareMap {
    func validate() throws {
        var issues: [SurfaceValidationIssue] = []
        if !(3 ... Self.currentVersion).contains(version) {
            issues.append(.init(
                .unsupportedVersion,
                subject: String(version),
                detail: L10n.text("不支持硬件映射版本 \(version)，需要重新学习")
            ))
        }
        var controls = Set<BCRControlID>()
        var identities = Set<MIDIControlID>()
        for entry in entries {
            if !controls.insert(entry.control).inserted {
                issues.append(.init(
                    .duplicateControlBinding,
                    subject: entry.control.shortName,
                    detail: L10n.text("物理控件重复绑定：\(entry.control.shortName)")
                ))
            }
            if !identities.insert(entry.midi).inserted {
                issues.append(.init(
                    .duplicateMIDIBinding,
                    subject: entry.midi.description,
                    detail: L10n.text("MIDI 身份重复：\(entry.midi)")
                ))
            }
            if entry.control.isContinuous, entry.midi.kind == .note {
                issues.append(.init(
                    .encoderMessageKind,
                    subject: entry.control.shortName,
                    detail: L10n.text("\(entry.control.shortName)：编码器只能绑定 CC 或 NRPN")
                ))
            }
        }
        let nrpnChannels = Set(entries.filter { $0.midi.kind == .nrpn }.map { $0.midi.channel })
        for entry in entries where entry.midi.kind == .controlChange && nrpnChannels.contains(entry.midi.channel) {
            if [6, 38, 98, 99, 100, 101, 121].contains(Int(entry.midi.number)) {
                issues.append(.init(.conflictingNRPNChannel, subject: entry.control.shortName,
                                    detail: L10n
                                        .text(
                                            "\(entry.control.shortName)：此通道的 CC \(entry.midi.number) 已保留给 NRPN，请改用其他通道或控制器"
                                        )))
            }
        }
        if !issues.isEmpty { throw SurfaceValidationError(issues) }
    }

    func migrated() throws -> HardwareMap {
        try validate()
        var result = self
        result.version = Self.currentVersion
        return result
    }
}
