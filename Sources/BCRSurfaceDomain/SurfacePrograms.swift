import BCRFoundation
import Foundation

public struct AssignmentPage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var assignments: [ControlAssignment]
    public init(id: String = UUID().uuidString, name: String, assignments: [ControlAssignment]) {
        self.id = id; self.name = name; self.assignments = assignments
    }
}

/// Macros contain bounded, synchronous parameter operations, never recursive macros or scripts.
public enum ParameterMutation: Codable, Hashable, Sendable {
    case set(ParameterID, Double)
    case step(ParameterID, Double)
    case toggle(ParameterID)
    case resetGroup(String)
}

public struct SurfaceMacro: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var actions: [ParameterMutation]
    public init(id: String = UUID().uuidString, name: String, actions: [ParameterMutation]) {
        self.id = id; self.name = name; self.actions = actions
    }
}

extension AssignmentPage {
    private enum CodingKeys: String, CodingKey { case id, name, assignments }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        assignments = try c.decode([ControlAssignment].self, forKey: .assignments)
        guard !id.isEmpty, id != SurfaceConfiguration.basePageID,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(assignments.map(\.control)).count == assignments.count
        else {
            throw MotionSafetyError(L10n.text("页面定义无效"))
        }
    }
}

extension SurfaceMacro {
    private enum CodingKeys: String, CodingKey { case id, name, actions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        actions = try c.decode([ParameterMutation].self, forKey: .actions)
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !actions.isEmpty, actions.count <= 64
        else {
            throw MotionSafetyError(L10n.text("宏定义无效"))
        }
        for action in actions {
            switch action {
            case let .set(id, value), let .step(id, value):
                guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.isFinite else {
                    throw MotionSafetyError(L10n.text("宏定义无效"))
                }
                if case .step = action, value == 0 { throw MotionSafetyError(L10n.text("宏定义无效")) }
            case let .toggle(id):
                guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw MotionSafetyError(L10n.text("宏定义无效")) }
            case .resetGroup: break
            }
        }
    }
}

public enum MacroStepRejection: LocalizedMessageError, Equatable, Sendable {
    case unknownParameter(ParameterID), requiresToggle(ParameterID), invalidValue(ParameterID), unknownGroup(String),
         unknownMacro
    public var localizedMessage: LocalizedMessage {
        switch self {
        case let .unknownParameter(id): "未知参数：\(id)"
        case let .requiresToggle(id): "切换动作需要开关型参数：\(id)"
        case let .invalidValue(id): "宏步骤数值无效：\(id)"
        case let .unknownGroup(group): "未知参数组：\(group)"
        case .unknownMacro: "未知宏"
        }
    }
}

public struct MacroExecution: Equatable, Sendable {
    public struct OperationResult: Identifiable, Equatable, Sendable {
        public enum Outcome: String, Sendable { case applied, rejected }
        public let id: Int
        public let outcome: Outcome
        public let reason: MacroStepRejection?
    }

    public let macroID: String
    public let name: String
    public let steps: [OperationResult]
    public let effects: [SurfaceEffect]
}
