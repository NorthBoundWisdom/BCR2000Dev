import BCRFoundation
import Foundation

public enum ParameterKind: String, Codable, Sendable, CaseIterable {
    /// A ranged value, e.g. a joint angle.
    case continuous
    /// Two states: `minimum` (off) and `maximum` (on).
    case toggle

    public var displayName: String {
        switch self {
        case .continuous: L10n.text("连续")
        case .toggle: L10n.text("开关")
        }
    }
}

public enum ParameterDefinitionError: Error, Equatable, LocalizedError, Sendable {
    case emptyIdentifier
    case emptyName
    case invalidRange(minimum: Double, maximum: Double)
    case duplicateIdentifier(ParameterID)
    case unknownParameter(ParameterID)
    case nonFiniteDefault
    case invalidStep

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier: L10n.text("参数 ID 不能为空")
        case .emptyName: L10n.text("参数名称不能为空")
        case let .invalidRange(minimum, maximum): L10n.text("范围无效：最小值 \(minimum) 必须小于最大值 \(maximum)")
        case let .duplicateIdentifier(id): L10n.text("参数 ID \(id) 已存在")
        case let .unknownParameter(id): L10n.text("未知参数 \(id)")
        case .nonFiniteDefault: L10n.text("默认值必须是有限数值")
        case .invalidStep: L10n.text("步长必须是正的有限数值，并能表示当前范围")
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
    public var agentWritable: Bool
    public var externallyProtected: Bool
    public var step: Double?

    public init(
        id: ParameterID,
        name: String,
        group: String = "",
        unit: String = "",
        minimum: Double = 0,
        maximum: Double = 127,
        defaultValue: Double? = nil,
        kind: ParameterKind = .continuous,
        agentWritable: Bool = true,
        externallyProtected: Bool = false,
        step: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.unit = unit
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue ?? minimum
        self.kind = kind
        self.agentWritable = agentWritable
        self.externallyProtected = externallyProtected
        self.step = step
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, group, unit, minimum, maximum, defaultValue, kind, agentWritable, externallyProtected, step
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(ParameterID.self, forKey: .id)
        func field<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) throws -> T {
            c.contains(key) ? try c.decode(type, forKey: key) : fallback
        }
        let legacyProtected = (decoder.userInfo[ParameterDecodingPolicy.legacyProtectedIDs] as? Set<ParameterID>)?
            .contains(id) == true
        self.init(
            id: id, name: try c.decode(String.self, forKey: .name),
            group: try field(String.self, .group, ""),
            unit: try field(String.self, .unit, ""),
            minimum: try field(Double.self, .minimum, 0),
            maximum: try field(Double.self, .maximum, 127),
            defaultValue: c.contains(.defaultValue) ? try c.decode(Double.self, forKey: .defaultValue) : nil,
            kind: try field(ParameterKind.self, .kind, .continuous),
            agentWritable: try field(Bool.self, .agentWritable, !legacyProtected),
            externallyProtected: try field(Bool.self, .externallyProtected, legacyProtected),
            step: try c.decodeIfPresent(Double.self, forKey: .step)
        )
    }

    public func validate() throws {
        guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParameterDefinitionError.emptyIdentifier
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParameterDefinitionError.emptyName
        }
        guard minimum.isFinite, maximum.isFinite, minimum < maximum, (maximum - minimum).isFinite else {
            throw ParameterDefinitionError.invalidRange(minimum: minimum, maximum: maximum)
        }
        guard defaultValue.isFinite else { throw ParameterDefinitionError.nonFiniteDefault }
        if let step {
            guard step.isFinite, step > 0, (minimum / step).isFinite, (maximum / step).isFinite else {
                throw ParameterDefinitionError.invalidStep
            }
        }
    }

    public var midpoint: Double {
        minimum + (maximum - minimum) / 2
    }

    /// Clamps to the range; toggles snap to `minimum` or `maximum`.
    public func clamp(_ value: Double) -> Double {
        let bounded = min(max(value, minimum), maximum)
        if kind == .toggle { return bounded >= midpoint ? maximum : minimum }
        guard let step else { return bounded }
        // Include both endpoints. Equal-distance ties select the lower value so
        // parameter snapping and the 7-bit projection have a stable round trip.
        let quotient = bounded / step
        let lower = min(max(quotient.rounded(.down) * step, minimum), maximum)
        let upper = min(max(quotient.rounded(.up) * step, minimum), maximum)
        return abs(bounded - lower) <= abs(upper - bounded) ? lower : upper
    }

    public func normalized(_ value: Double) -> Double {
        (clamp(value) - minimum) / (maximum - minimum)
    }

    /// 7-bit value for LED ring / button feedback.
    public func midiValue(for value: Double, snap: Bool = true) -> UInt8 {
        let normalized = snap ? normalized(value) : (min(max(value, minimum), maximum) - minimum) / (maximum - minimum)
        return UInt8((normalized * 127).rounded())
    }

    /// Parameter value represented by a 7-bit control value.
    public func value(fromMIDI midi: UInt8) -> Double {
        let midi = min(midi, 127)
        if kind == .toggle {
            return midi >= 64 ? maximum : minimum
        }
        return clamp(minimum + (maximum - minimum) * Double(midi) / 127)
    }

    public func formatted(_ value: Double, snap: Bool = true, minimumFractionDigits: Int = 0) -> String {
        guard value.isFinite else { return L10n.text("无效值") }
        let value = snap ? clamp(value) : value
        if kind == .toggle {
            return value >= midpoint ? L10n.text("开") : L10n.text("关")
        }
        let span = maximum - minimum
        let spanDigits = span <= 2 ? 2 : (span <= 20 ? 1 : 0)
        var stepDigits = 0
        if let step {
            for digits in 0 ... 6 {
                let scaled = step * pow(10, Double(digits))
                if scaled.isFinite, abs(scaled - scaled.rounded()) <= scaled.ulp * 4 {
                    stepDigits = digits
                    break
                }
                stepDigits = 6
            }
        }
        let digits = max(spanDigits, stepDigits, minimumFractionDigits)
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
        case .toggle: L10n.text("切换")
        case .momentary: L10n.text("按住")
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
    case stepParameter(id: ParameterID, step: Double, wraps: Bool)
    case setParameter(id: ParameterID, value: Double)
    case cycleParameter(id: ParameterID, values: [Double])
    case switchPage(String)
    case runMacro(String)

    public var parameterID: ParameterID? {
        switch self {
        case let .parameter(id), let .stepParameter(id, _, _), let .setParameter(id, _), let .cycleParameter(id, _): id
        case .agentPrimaryAction, .resetGroup, .switchPage, .runMacro: nil
        }
    }

    /// Triggers fire once per press and only make sense on buttons.
    public var isTrigger: Bool {
        switch self {
        case .parameter: false
        case .agentPrimaryAction, .resetGroup, .stepParameter, .setParameter, .cycleParameter, .switchPage,
             .runMacro: true
        }
    }
}

/// BCR manual §4.3: Relative 1 is two's complement, Relative 2 is binary offset.
/// Exact device acceleration/feedback behaviour is modelled in Mock only; 待 R1 实机验证.
public enum EncoderMode: String, Codable, CaseIterable, Sendable {
    case absolute, relative1, relative2

    public func delta(value: UInt16, maximum: UInt16) -> Int {
        guard self != .absolute, value <= maximum else { return 0 }
        let center = (Int(maximum) + 1) / 2
        switch self {
        case .absolute: return 0
        case .relative1: return Int(value) < center ? Int(value) : Int(value) - Int(maximum) - 1
        case .relative2: return Int(value) - center
        }
    }

    public func encoded(delta: Int, maximum: UInt16) -> UInt16 {
        let center = (Int(maximum) + 1) / 2
        let bounded = min(max(delta, -center + 1), center - 1)
        switch self {
        case .absolute: return 0
        case .relative1: return UInt16(bounded < 0 ? Int(maximum) + 1 + bounded : bounded)
        case .relative2: return UInt16(center + bounded)
        }
    }
}

public struct ControlAssignment: Codable, Equatable, Sendable, Identifiable {
    public let control: BCRControlID
    public var target: ControlTarget
    public var buttonBehavior: ButtonBehavior
    /// Reverses the direction of an encoder or the on/off sense of a button.
    public var inverted: Bool
    public var encoderMode: EncoderMode
    /// Units per relative tick; encoded magnitude is the acceleration factor.
    public var encoderStep: Double

    public var id: BCRControlID { control }

    public init(
        control: BCRControlID,
        target: ControlTarget,
        buttonBehavior: ButtonBehavior = .toggle,
        inverted: Bool = false,
        encoderMode: EncoderMode = .absolute,
        encoderStep: Double = 1
    ) {
        self.control = control
        self.target = target
        self.buttonBehavior = buttonBehavior
        self.inverted = inverted
        self.encoderMode = encoderMode
        self.encoderStep = encoderStep
    }

    private enum CodingKeys: String,
        CodingKey { case control, target, buttonBehavior, inverted, encoderMode, encoderStep }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(control: try c.decode(BCRControlID.self, forKey: .control),
                  target: try c.decode(ControlTarget.self, forKey: .target),
                  buttonBehavior: try c.decode(ButtonBehavior.self, forKey: .buttonBehavior),
                  inverted: try c.decode(Bool.self, forKey: .inverted),
                  encoderMode: c.contains(.encoderMode) ? try c
                      .decode(EncoderMode.self, forKey: .encoderMode) : .absolute,
                  encoderStep: c.contains(.encoderStep) ? try c.decode(Double.self, forKey: .encoderStep) : 1)
    }
}

public enum ControlAssignmentError: Error, Equatable, LocalizedError, Sendable {
    case triggerRequiresButton(BCRControlID)
    case unknownParameter(ParameterID)

    public var errorDescription: String? {
        switch self {
        case let .triggerRequiresButton(control): L10n.text("\(control.shortName) 是编码器，触发类功能只能分配给按键")
        case let .unknownParameter(id): L10n.text("未知参数 \(id)")
        }
    }
}

/// User-editable function layer: parameter definitions plus what every physical control does.
/// It contains no MIDI identities, so it can be shared between the mock and real devices.
public struct SurfaceConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 7
    public static let basePageID = "__base__"

    public var version: Int
    public var name: String
    public private(set) var parameters: [ParameterDefinition]
    private var baseAssignments: [ControlAssignment]
    public private(set) var pages: [AssignmentPage]
    public private(set) var macros: [SurfaceMacro]
    public private(set) var activePageID: String?
    public var allAssignmentSets: [[ControlAssignment]] { [baseAssignments] + pages.map(\.assignments) }
    public private(set) var assignments: [ControlAssignment] {
        get { activePageID.flatMap { id in pages.first { $0.id == id }?.assignments } ?? baseAssignments }
        set {
            if let id = activePageID,
               let index = pages.firstIndex(where: { $0.id == id }) { pages[index].assignments = newValue }
            else { baseAssignments = newValue }
        }
    }

    public init(
        version: Int = SurfaceConfiguration.currentVersion,
        name: String,
        parameters: [ParameterDefinition] = [],
        assignments: [ControlAssignment] = [],
        pages: [AssignmentPage] = [], macros: [SurfaceMacro] = [], activePageID: String? = nil
    ) {
        self.version = version
        self.name = name
        self.parameters = parameters
        self.baseAssignments = assignments.sorted { $0.control < $1.control }
        self.pages = pages
        self.macros = macros
        self.activePageID = activePageID
    }

    private enum CodingKeys: String,
        CodingKey { case version, name, parameters, assignments, pages, macros, activePageID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        if version >= 5, !container.contains(.pages) || !container.contains(.macros) {
            throw MotionSafetyError(L10n.text("页面定义无效"))
        }
        if version >= 6, container.contains(.activePageID) {
            throw MotionSafetyError(L10n.text("当前页面属于会话状态，不能写入配置文件"))
        }
        self.init(
            version: version,
            name: try container.decode(String.self, forKey: .name),
            parameters: try container.decode([ParameterDefinition].self, forKey: .parameters),
            assignments: try container.decode([ControlAssignment].self, forKey: .assignments),
            pages: container.contains(.pages) ? try container.decode([AssignmentPage].self, forKey: .pages) : [],
            macros: container.contains(.macros) ? try container.decode([SurfaceMacro].self, forKey: .macros) : [],
            activePageID: version < 6 ? try container.decodeIfPresent(String.self, forKey: .activePageID) : nil
        )
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(baseAssignments, forKey: .assignments)
        try c.encode(pages, forKey: .pages)
        try c.encode(macros, forKey: .macros)
        // activePageID is session state; exported/durable configurations always open on the base page.
    }

    public var pageNavigationWarning: String? {
        guard !pages.isEmpty else { return nil }
        let current = activePageID ?? Self.basePageID
        let hasExit = assignments.contains { assignment in
            if case let .switchPage(id) = assignment.target { return id != current }
            return false
        }
        return hasExit ? nil : L10n.text("当前页面没有切换到其他页面的按键，请从设置选择页面")
    }

    public mutating func addPage(_ page: AssignmentPage) throws {
        var candidate = self
        candidate.pages.append(page)
        try candidate.validate()
        self = candidate
    }

    public mutating func selectPage(_ id: String?) throws {
        let id = id == Self.basePageID ? nil : id
        guard id == nil || pages.contains(where: { $0.id == id }) else {
            throw MotionSafetyError(L10n.text("未知页面"))
        }
        activePageID = id
    }

    public mutating func addMacro(_ macro: SurfaceMacro) throws {
        var candidate = self
        candidate.macros.append(macro)
        try candidate.validate()
        self = candidate
    }

    public mutating func deletePage(_ id: String) {
        pages.removeAll { $0.id == id }
        if activePageID == id { activePageID = nil }
        baseAssignments.removeAll { $0.target == .switchPage(id) }
        for index in pages.indices { pages[index].assignments.removeAll { $0.target == .switchPage(id) } }
    }

    public mutating func deleteMacro(_ id: String) {
        macros.removeAll { $0.id == id }
        baseAssignments.removeAll { $0.target == .runMacro(id) }
        for index in pages.indices { pages[index].assignments.removeAll { $0.target == .runMacro(id) } }
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

    public func controls(targetingParameter id: ParameterID) -> [BCRControlID] {
        assignments.filter { $0.target.parameterID == id }.map(\.control)
    }

    public mutating func assign(_ assignment: ControlAssignment) throws {
        if assignment.target.isTrigger, assignment.control.isContinuous {
            throw ControlAssignmentError.triggerRequiresButton(assignment.control)
        }
        if let id = assignment.target.parameterID, parameter(id) == nil {
            throw ControlAssignmentError.unknownParameter(id)
        }
        var candidate = self
        candidate.assignments.removeAll { $0.control == assignment.control }
        candidate.assignments.append(assignment)
        candidate.assignments.sort { $0.control < $1.control }
        try candidate.validate()
        self = candidate
    }

    public mutating func clearAssignment(for control: BCRControlID) {
        assignments.removeAll { $0.control == control }
    }

    public mutating func addParameter(_ definition: ParameterDefinition) throws {
        try definition.validate()
        guard parameter(definition.id) == nil else {
            throw ParameterDefinitionError.duplicateIdentifier(definition.id)
        }
        var candidate = self
        candidate.parameters.append(definition)
        try candidate.validate()
        self = candidate
    }

    public mutating func updateParameter(_ definition: ParameterDefinition) throws {
        try definition.validate()
        guard let position = parameters.firstIndex(where: { $0.id == definition.id }) else {
            throw ParameterDefinitionError.unknownParameter(definition.id)
        }
        var definition = definition
        definition.defaultValue = definition.clamp(definition.defaultValue)
        var candidate = self
        candidate.parameters[position] = definition
        try candidate.validate()
        self = candidate
    }

    /// Removes the parameter and every assignment that targets it.
    public mutating func removeParameter(_ id: ParameterID) {
        let previousGroup = parameter(id)?.group
        parameters.removeAll { $0.id == id }
        baseAssignments.removeAll { $0.target.parameterID == id }
        for index in pages.indices { pages[index].assignments.removeAll { $0.target.parameterID == id } }
        macros = macros.filter { macro in !macro.actions.contains { action in
            switch action { case let .set(parameter, _),
                 let .step(parameter, _): parameter == id; case .resetGroup: false }
        } }
        let macroIDs = Set(macros.map(\.id))
        baseAssignments
            .removeAll { if case let .runMacro(id) = $0.target { return !macroIDs.contains(id) }; return false }
        for index in pages.indices {
            pages[index].assignments
                .removeAll { if case let .runMacro(id) = $0.target { return !macroIDs.contains(id) }; return false }
        }
        if let previousGroup, !parameterGroups.contains(previousGroup) {
            baseAssignments.removeAll { $0.target == .resetGroup(previousGroup) }
            for index in pages
                .indices { pages[index].assignments.removeAll { $0.target == .resetGroup(previousGroup) } }
            let removed = macros.filter { $0.actions.contains(.resetGroup(previousGroup)) }.map(\.id)
            for id in removed { deleteMacro(id) }
        }
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
