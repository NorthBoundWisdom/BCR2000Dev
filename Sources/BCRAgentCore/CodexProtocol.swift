import Foundation

public enum CodexSchema {
    public static let cliVersion = "0.145.0"
    public static let stableSchemaDirectory = "Schemas/Codex/\(cliVersion)/stable"
}

public enum CodexRequestID: Codable, Hashable, Sendable {
    case number(Int)
    case string(String)

    public init(_ value: Int) { self = .number(value) }

    public init(_ value: String) { self = .string(value) }
}

public enum JSONValue: Equatable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        case let .object(values):
            try container.encode(values)
        }
    }
}

public struct CodexErrorPayload: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct CodexEnvelope: Codable, Equatable, Sendable {
    public enum Kind: Equatable {
        case request
        case response
        case notification
        case unknown
    }

    public var jsonrpc: String?
    public var id: CodexRequestID?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: CodexErrorPayload?

    public init(
        jsonrpc: String? = "2.0",
        id: CodexRequestID? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: CodexErrorPayload? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public var kind: Kind {
        if method != nil {
            return id == nil ? .notification : .request
        }
        if id != nil && (result != nil || error != nil) {
            return .response
        }
        return .unknown
    }

    public var isResponse: Bool {
        if id == nil {
            return false
        }
        return result != nil || error != nil
    }

    public func encodeJSON(pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        }
        let data = try encoder.encode(self)
        guard var string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        if pretty {
            string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return string
    }

    public static func decodeJSON(_ text: String) throws -> CodexEnvelope {
        guard let data = text.data(using: .utf8) else {
            throw NSError(
                domain: "CodexProtocol",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 payload"]
            )
        }
        return try JSONDecoder().decode(CodexEnvelope.self, from: data)
    }
}

public enum CodexMethod: String {
    case initialize = "initialize"
    case initialized = "initialized"
    case accountRead = "account/read"
    case modelList = "model/list"
    case threadStart = "thread/start"
    case threadResume = "thread/resume"
    case turnStart = "turn/start"
    case turnInterrupt = "turn/interrupt"
    case commandExecutionRequestApproval = "item/commandExecution/requestApproval"
    case fileChangeRequestApproval = "item/fileChange/requestApproval"
}

public struct CodexPermissionPolicy: Codable, Equatable, Sendable {
    public enum Profile: String, Codable, Equatable, Sendable {
        case safeRead = "safeRead"
        case workspaceWrite = "workspaceWrite"
    }

    public var type: Profile
    public var networkAccess: Bool
    public var writableRoots: [String]?

    public init(type: Profile, networkAccess: Bool = false, writableRoots: [String]? = nil) {
        self.type = type
        self.networkAccess = networkAccess
        self.writableRoots = writableRoots
    }
}

public struct CodexApprovalPolicy: Codable, Equatable, Sendable {
    public let approver: String

    public init(approver: String = "user") {
        self.approver = approver
    }
}

public struct CodexTurnIntent: Codable, Equatable, Sendable {
    public var modelID: String?
    public var effortID: String?
    public var permission: CodexPermissionPolicy
    public var priority: Int
    public var timeoutMs: Int?

    public init(
        modelID: String? = nil,
        effortID: String? = nil,
        permission: CodexPermissionPolicy,
        priority: Int = 0,
        timeoutMs: Int? = nil
    ) {
        self.modelID = modelID
        self.effortID = effortID
        self.permission = permission
        self.priority = priority
        self.timeoutMs = timeoutMs
    }
}
