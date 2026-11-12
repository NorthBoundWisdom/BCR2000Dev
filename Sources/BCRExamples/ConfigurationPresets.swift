import BCRFoundation
import BCRSurfaceDomain
import Foundation
import enum ExampleParameterSets.ExampleParameterSets

/// Built-in configurations a user can load. `starter` is what a fresh install opens with;
/// domain-specific examples are loaded explicitly.
public enum ConfigurationPreset: String, CaseIterable, Identifiable, Sendable {
    case starter, robotArm

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .starter: L10n.text("默认配置")
        case .robotArm: L10n.text("机械臂示例")
        }
    }

    public var summary: String {
        switch self {
        case .starter: L10n.text("8 个通用参数（P1-1…P1-8）、Agent 1–8（B1 行）、B2-8 复位")
        case .robotArm: L10n.text("J1–J6、夹爪、速度（P1-1…P1-8）、Agent 1–8（B1 行）、B2-1 使能、B2-8 复位")
        }
    }

    public func makeConfiguration() -> SurfaceConfiguration {
        switch self {
        case .starter: .starter()
        case .robotArm: .robotArmDemo()
        }
    }
}

/// Translate only exact built-in names at presentation time; persisted names and group keys stay verbatim.
public enum BuiltInNamePresentation {
    public static func displayName(_ savedName: String, language: AppLanguage = L10n.language) -> String {
        guard let message = messagesByName[savedName] else { return savedName }
        return L10n.text(message, language: language)
    }

    /// The value to store after the user edited a field that shows `displayName(saved)`.
    ///
    /// Text equal to what the field displays means the name itself was not changed (typing a
    /// character and deleting it, or the field committing unchanged text), so the stored spelling
    /// is kept. Otherwise a group referenced by its stored string would be split from its other
    /// parameters and its reset button by a mere focus change in another UI language.
    public static func editedName(_ text: String, replacing saved: String,
                                  language: AppLanguage = L10n.language) -> String
    {
        text == displayName(saved, language: language) ? saved : text
    }

    private static let messagesByName: [String: LocalizedMessage] = {
        let names: [LocalizedMessage] = [
            "J1 底座旋转", "J2 肩部", "J3 肘部", "J4 腕部俯仰", "J5 腕部旋转", "J6 末端旋转",
            "夹爪开合", "运动速度", "使能", "机械臂", "通用", "机械臂示例", "默认配置"
        ] + (1 ... 8).map { "参数 \($0)" }
        var result: [String: LocalizedMessage] = [:]
        for message in names {
            for language in [AppLanguage.chinese, .english] {
                result[L10n.text(message, language: language)] = message
            }
        }
        return result
    }()
}

public extension SurfaceConfiguration {
    static let starterGroup = L10n.text("通用")
    static let robotArmGroup = L10n.text("机械臂")

    /// Neutral first-launch layout: eight generic percentage parameters on push encoders group 1,
    /// agent slots on button row 1 and a group reset on B2-8. Nothing here assumes a use case.
    static func starter() -> SurfaceConfiguration {
        let parameters = (1 ... 8).map { index in
            ParameterDefinition(
                id: ParameterID("general.\(index)"), name: L10n.text("参数 \(index)"), group: starterGroup,
                unit: "%", minimum: 0, maximum: 100, defaultValue: 0
            )
        }
        var assignments = parameters.enumerated().map { position, parameter in
            ControlAssignment(control: .pushEncoder(group: 1, position + 1), target: .parameter(parameter.id))
        }
        for slot in 1 ... 8 {
            assignments.append(
                ControlAssignment(control: .button(row: 1, slot), target: .agentPrimaryAction(AgentSlotID(slot)))
            )
        }
        assignments.append(ControlAssignment(control: .button(row: 2, 8), target: .resetGroup(starterGroup)))
        return SurfaceConfiguration(name: ConfigurationPreset.starter.title, parameters: parameters,
                                    assignments: assignments)
    }

    /// Example layout: a 6-axis arm on push encoders group 1, agent slots on button row 1,
    /// arm enable / home on button row 2. Users can reassign everything in the inspector.
    static func robotArmDemo() -> SurfaceConfiguration {
        let group = robotArmGroup
        let definitions: [ParameterDefinition]
        do {
            definitions = try ExampleParameterSets.referenceArm().map { definition in
                let name: LocalizedMessage = switch definition.nameKey {
                case "example.arm.j1": "J1 底座旋转"
                case "example.arm.j2": "J2 肩部"
                case "example.arm.j3": "J3 肘部"
                case "example.arm.j4": "J4 腕部俯仰"
                case "example.arm.j5": "J5 腕部旋转"
                case "example.arm.j6": "J6 末端旋转"
                case "example.arm.gripper": "夹爪开合"
                case "example.arm.speed": "运动速度"
                case "example.arm.enabled": "使能"
                default: .init(stringLiteral: definition.nameKey)
                }
                return ParameterDefinition(id: definition.id, name: L10n.text(name), group: group,
                                           unit: definition.unit, minimum: definition.minimum,
                                           maximum: definition.maximum,
                                           defaultValue: definition.defaultValue,
                                           kind: definition.kind == .toggle ? .toggle : .continuous,
                                           agentWritable: definition.agentWritable,
                                           externallyProtected: definition.externallyProtected,
                                           step: definition.step)
            }
        } catch { preconditionFailure("Invalid built-in shared reference-arm parameter data: \(error)") }
        let parameters = definitions

        var assignments: [ControlAssignment] = []
        for (position, parameter) in parameters.prefix(8).enumerated() {
            assignments.append(
                ControlAssignment(control: .pushEncoder(group: 1, position + 1), target: .parameter(parameter.id))
            )
        }
        for slot in 1 ... 8 {
            assignments.append(
                ControlAssignment(control: .button(row: 1, slot), target: .agentPrimaryAction(AgentSlotID(slot)))
            )
        }
        assignments.append(ControlAssignment(control: .button(row: 2, 1), target: .parameter("arm.enabled")))
        assignments.append(ControlAssignment(control: .button(row: 2, 8), target: .resetGroup(group)))

        return SurfaceConfiguration(name: L10n.text("机械臂示例"), parameters: parameters, assignments: assignments)
    }
}

public enum LegacyExampleProtection {
    public static var parameterIDs: Set<ParameterID> { ExampleParameterSets.protectedParameterIDs }
}
