import Foundation

public struct ParameterID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible,
    ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: ParameterID, rhs: ParameterID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ParameterKind: String, Codable, Sendable, CaseIterable {
    /// A ranged value, e.g. a joint angle.
    case continuous
    /// Two states: `minimum` (off) and `maximum` (on).
    case toggle

    public var displayName: String {
        switch self {
        case .continuous: "连续"
        case .toggle: "开关"
        }
    }
}

public enum ParameterDefinitionError: Error, Equatable, LocalizedError, Sendable {
    case emptyIdentifier
    case emptyName
    case invalidRange(minimum: Double, maximum: Double)
    case duplicateIdentifier(ParameterID)
    case unknownParameter(ParameterID)

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier: "参数 ID 不能为空"
        case .emptyName: "参数名称不能为空"
        case let .invalidRange(minimum, maximum): "范围无效：最小值 \(minimum) 必须小于最大值 \(maximum)"
        case let .duplicateIdentifier(id): "参数 ID \(id) 已存在"
        case let .unknownParameter(id): "未知参数 \(id)"
        }
    }
}

/// A software-side value that physical controls can drive and that the app writes back to them.
public struct ParameterDefinition: Identifiable, Codable, Equatable, Sendable {
    public let id: ParameterID
    public var name: String
    public var group: String
    public var unit: String
    public var minimum: Double
    public var maximum: Double
    public var defaultValue: Double
    public var kind: ParameterKind

    public init(
        id: ParameterID,
        name: String,
        group: String = "",
        unit: String = "",
        minimum: Double = 0,
        maximum: Double = 127,
        defaultValue: Double? = nil,
        kind: ParameterKind = .continuous
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.unit = unit
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue ?? minimum
        self.kind = kind
    }

    public func validate() throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ParameterDefinitionError.emptyIdentifier
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ParameterDefinitionError.emptyName
        }
        guard minimum.isFinite, maximum.isFinite, minimum < maximum else {
            throw ParameterDefinitionError.invalidRange(minimum: minimum, maximum: maximum)
        }
    }

    public var midpoint: Double {
        (minimum + maximum) / 2
    }

    /// Clamps to the range; toggles snap to `minimum` or `maximum`.
    public func clamp(_ value: Double) -> Double {
        let bounded = min(max(value, minimum), maximum)
        guard kind == .toggle else {
            return bounded
        }
        return bounded >= midpoint ? maximum : minimum
    }

    public func normalized(_ value: Double) -> Double {
        (clamp(value) - minimum) / (maximum - minimum)
    }

    /// 7-bit value for LED ring / button feedback.
    public func midiValue(for value: Double) -> UInt8 {
        UInt8((normalized(value) * 127).rounded())
    }

    /// Parameter value represented by a 7-bit control value.
    public func value(fromMIDI midi: UInt8) -> Double {
        let midi = min(midi, 127)
        if kind == .toggle {
            return midi >= 64 ? maximum : minimum
        }
        return minimum + (maximum - minimum) * Double(midi) / 127
    }

    public func formatted(_ value: Double) -> String {
        let value = clamp(value)
        if kind == .toggle {
            return value >= midpoint ? "开" : "关"
        }
        let span = maximum - minimum
        let digits = span <= 2 ? 2 : (span <= 20 ? 1 : 0)
        let number = value.formatted(.number.precision(.fractionLength(digits)))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}

public enum ButtonBehavior: String, Codable, Sendable, CaseIterable {
    /// Each press flips the target; the LED holds the state.
    case toggle
    /// The target is on only while the button is held.
    case momentary

    public var displayName: String {
        switch self {
        case .toggle: "切换"
        case .momentary: "按住"
        }
    }
}

/// What a physical control does in the software.
public enum ControlTarget: Codable, Hashable, Sendable {
    case parameter(ParameterID)
    /// Starts / interrupts / approves a mock agent slot, depending on its state.
    case agentPrimaryAction(AgentSlotID)
    /// Returns every parameter of a group to its default value (e.g. robot arm "home").
    case resetGroup(String)

    /// Triggers fire once per press and only make sense on buttons.
    public var isTrigger: Bool {
        switch self {
        case .parameter: false
        case .agentPrimaryAction, .resetGroup: true
        }
    }
}

public struct ControlAssignment: Codable, Equatable, Sendable, Identifiable {
    public let control: BCRControlID
    public var target: ControlTarget
    public var buttonBehavior: ButtonBehavior
    /// Reverses the direction of an encoder or the on/off sense of a button.
    public var inverted: Bool

    public var id: BCRControlID { control }

    public init(
        control: BCRControlID,
        target: ControlTarget,
        buttonBehavior: ButtonBehavior = .toggle,
        inverted: Bool = false
    ) {
        self.control = control
        self.target = target
        self.buttonBehavior = buttonBehavior
        self.inverted = inverted
    }
}

public enum ControlAssignmentError: Error, Equatable, LocalizedError, Sendable {
    case triggerRequiresButton(BCRControlID)
    case unknownParameter(ParameterID)

    public var errorDescription: String? {
        switch self {
        case let .triggerRequiresButton(control): "\(control.shortName) 是编码器，触发类功能只能分配给按键"
        case let .unknownParameter(id): "未知参数 \(id)"
        }
    }
}

/// User-editable function layer: parameter definitions plus what every physical control does.
/// It contains no MIDI identities, so it can be shared between the mock and real devices.
public struct SurfaceConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public private(set) var parameters: [ParameterDefinition]
    public private(set) var assignments: [ControlAssignment]

    public init(
        version: Int = SurfaceConfiguration.currentVersion,
        name: String,
        parameters: [ParameterDefinition] = [],
        assignments: [ControlAssignment] = []
    ) {
        self.version = version
        self.name = name
        self.parameters = parameters
        self.assignments = assignments.sorted { $0.control < $1.control }
    }

    public var parameterGroups: [String] {
        var seen = Set<String>()
        return parameters.map(\.group).filter { seen.insert($0).inserted }
    }

    public func parameter(_ id: ParameterID) -> ParameterDefinition? {
        parameters.first { $0.id == id }
    }

    public func assignment(for control: BCRControlID) -> ControlAssignment? {
        assignments.first { $0.control == control }
    }

    public func controls(targeting target: ControlTarget) -> [BCRControlID] {
        assignments.filter { $0.target == target }.map(\.control)
    }

    public mutating func assign(_ assignment: ControlAssignment) throws {
        if assignment.target.isTrigger, assignment.control.isContinuous {
            throw ControlAssignmentError.triggerRequiresButton(assignment.control)
        }
        if case let .parameter(id) = assignment.target, parameter(id) == nil {
            throw ControlAssignmentError.unknownParameter(id)
        }
        assignments.removeAll { $0.control == assignment.control }
        assignments.append(assignment)
        assignments.sort { $0.control < $1.control }
    }

    public mutating func clearAssignment(for control: BCRControlID) {
        assignments.removeAll { $0.control == control }
    }

    public mutating func addParameter(_ definition: ParameterDefinition) throws {
        try definition.validate()
        guard parameter(definition.id) == nil else {
            throw ParameterDefinitionError.duplicateIdentifier(definition.id)
        }
        parameters.append(definition)
    }

    public mutating func updateParameter(_ definition: ParameterDefinition) throws {
        try definition.validate()
        guard let position = parameters.firstIndex(where: { $0.id == definition.id }) else {
            throw ParameterDefinitionError.unknownParameter(definition.id)
        }
        var definition = definition
        definition.defaultValue = definition.clamp(definition.defaultValue)
        parameters[position] = definition
    }

    /// Removes the parameter and every assignment that targets it.
    public mutating func removeParameter(_ id: ParameterID) {
        parameters.removeAll { $0.id == id }
        assignments.removeAll { $0.target == .parameter(id) }
    }

    /// A free parameter ID with the given prefix, e.g. `custom.3`.
    public func makeParameterID(prefix: String = "custom") -> ParameterID {
        var counter = parameters.count + 1
        while parameter(ParameterID("\(prefix).\(counter)")) != nil {
            counter += 1
        }
        return ParameterID("\(prefix).\(counter)")
    }
}

public extension SurfaceConfiguration {
    static let robotArmGroup = "机械臂"

    /// Starter layout: a 6-axis arm on push encoders group 1, agent slots on button row 1,
    /// arm enable / home on button row 2. Users can reassign everything in the inspector.
    static func robotArmDemo() -> SurfaceConfiguration {
        let group = robotArmGroup
        let parameters: [ParameterDefinition] = [
            .init(id: "arm.j1", name: "J1 底座旋转", group: group, unit: "°", minimum: -180, maximum: 180, defaultValue: 0),
            .init(id: "arm.j2", name: "J2 肩部", group: group, unit: "°", minimum: -90, maximum: 90, defaultValue: 30),
            .init(id: "arm.j3", name: "J3 肘部", group: group, unit: "°", minimum: -135, maximum: 135, defaultValue: -60),
            .init(id: "arm.j4", name: "J4 腕部俯仰", group: group, unit: "°", minimum: -120, maximum: 120, defaultValue: -20),
            .init(id: "arm.j5", name: "J5 腕部旋转", group: group, unit: "°", minimum: -180, maximum: 180, defaultValue: 0),
            .init(id: "arm.j6", name: "J6 末端旋转", group: group, unit: "°", minimum: -180, maximum: 180, defaultValue: 0),
            .init(id: "arm.gripper", name: "夹爪开合", group: group, unit: "%", minimum: 0, maximum: 100, defaultValue: 40),
            .init(id: "arm.speed", name: "运动速度", group: group, unit: "%", minimum: 0, maximum: 100, defaultValue: 50),
            .init(id: "arm.enabled", name: "使能", group: group, minimum: 0, maximum: 1, defaultValue: 0, kind: .toggle),
        ]

        var assignments: [ControlAssignment] = []
        for (position, parameter) in parameters.prefix(8).enumerated() {
            assignments.append(
                ControlAssignment(control: .pushEncoder(group: 1, position + 1), target: .parameter(parameter.id))
            )
        }
        for slot in 1...8 {
            assignments.append(
                ControlAssignment(control: .button(row: 1, slot), target: .agentPrimaryAction(AgentSlotID(slot)))
            )
        }
        assignments.append(ControlAssignment(control: .button(row: 2, 1), target: .parameter("arm.enabled")))
        assignments.append(ControlAssignment(control: .button(row: 2, 8), target: .resetGroup(group)))

        return SurfaceConfiguration(name: "机械臂示例", parameters: parameters, assignments: assignments)
    }
}
