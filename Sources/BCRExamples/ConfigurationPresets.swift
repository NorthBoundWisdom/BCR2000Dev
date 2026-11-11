import BCRFoundation
import BCRSurfaceDomain
import Foundation

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
        let parameters: [ParameterDefinition] = [
            .init(
                id: "arm.j1",
                name: L10n.text("J1 底座旋转"),
                group: group,
                unit: "°",
                minimum: -180,
                maximum: 180,
                defaultValue: 0
            ),
            .init(
                id: "arm.j2",
                name: L10n.text("J2 肩部"),
                group: group,
                unit: "°",
                minimum: -90,
                maximum: 90,
                defaultValue: 30
            ),
            .init(
                id: "arm.j3",
                name: L10n.text("J3 肘部"),
                group: group,
                unit: "°",
                minimum: -135,
                maximum: 135,
                defaultValue: -60
            ),
            .init(
                id: "arm.j4",
                name: L10n.text("J4 腕部俯仰"),
                group: group,
                unit: "°",
                minimum: -120,
                maximum: 120,
                defaultValue: -20
            ),
            .init(
                id: "arm.j5",
                name: L10n.text("J5 腕部旋转"),
                group: group,
                unit: "°",
                minimum: -180,
                maximum: 180,
                defaultValue: 0
            ),
            .init(
                id: "arm.j6",
                name: L10n.text("J6 末端旋转"),
                group: group,
                unit: "°",
                minimum: -180,
                maximum: 180,
                defaultValue: 0
            ),
            .init(
                id: "arm.gripper",
                name: L10n.text("夹爪开合"),
                group: group,
                unit: "%",
                minimum: 0,
                maximum: 100,
                defaultValue: 40
            ),
            .init(
                id: "arm.speed",
                name: L10n.text("运动速度"),
                group: group,
                unit: "%",
                minimum: 0,
                maximum: 100,
                defaultValue: 50
            ),
            .init(
                id: "arm.enabled",
                name: L10n.text("使能"),
                group: group,
                minimum: 0,
                maximum: 1,
                defaultValue: 0,
                kind: .toggle,
                agentWritable: false,
                externallyProtected: true
            )
        ]

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
    public static let parameterIDs: Set<ParameterID> = ["arm.enabled"]
}
