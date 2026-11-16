import BCRFoundation
import Foundation

/// Durable named value snapshot. String keys keep the common cross-host JSON object shape.
public struct ParameterScene: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var values: [String: Double]
    public init(id: String, name: String, values: [String: Double]) {
        self.id = id; self.name = name; self.values = values
    }

    public func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 256,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024,
              values.count <= 256,
              values
                  .allSatisfy({ !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.isFinite })
        else { throw ParameterSceneError.invalidScene(id) }
    }

    private enum CodingKeys: String, CodingKey { case id, name, values }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  values: try c.decode([String: Double].self, forKey: .values))
        try validate()
    }
}

public enum ParameterSceneError: LocalizedMessageError, Equatable, Sendable {
    case invalidScene(String), protectedParameter(ParameterID), overwriteRequiresConfirmation, unknownScene
    public var localizedMessage: LocalizedMessage {
        switch self {
        case let .invalidScene(id): "场景定义无效：\(id)"
        case .overwriteRequiresConfirmation: "覆盖场景前需要确认。"
        case .unknownScene: "未知场景"
        case let .protectedParameter(id): "场景包含当前受保护的数值变化：\(id)"
        }
    }
}

public struct SceneRecallResult: Equatable, Sendable {
    public let missingParameters: [String]
}

public extension SurfaceConfiguration {
    mutating func setScenes(_ scenes: [ParameterScene]?) throws {
        var candidate = self
        candidate.scenes = scenes
        try candidate.validate()
        self = candidate
    }
}
