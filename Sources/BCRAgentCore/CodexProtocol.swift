import Foundation

public enum CodexSchema {
    public static let cliVersion = "0.145.0"
    public static let stableSchemaDirectory = "Schemas/Codex/\(cliVersion)/stable"
}

public enum CodexProtocolError: Error, LocalizedError, Sendable {
    case malformedJSON(String)
    case nonObjectPayload(method: String)
    case missingPayloadField(String)
    case invalidPayloadField(String)

    public var errorDescription: String? {
        switch self {
        case let .malformedJSON(message):
            "协议数据错误：\(message)"
        case let .nonObjectPayload(method):
            "\(method) 返回参数不是对象结构"
        case let .missingPayloadField(field):
            "缺少必要字段：\(field)"
        case let .invalidPayloadField(field):
            "字段类型不匹配：\(field)"
        }
    }
}

public enum CodexRequestID: Codable, Hashable, Sendable {
    case number(Int)
    case string(String)

    public init(_ value: Int) { self = .number(value) }

    public init(_ value: String) { self = .string(value) }

    public var stringValue: String {
        switch self {
        case let .number(value):
            String(value)
        case let .string(value):
            value
        }
    }
}

public indirect enum JSONValue: Equatable, Codable, Sendable {
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

    public var stringValue: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self {
            value
        } else {
            nil
        }
    }

    public var intValue: Int? {
        switch self {
        case let .number(value):
            value
        case let .double(value):
            Int(exactly: value.rounded())
        default:
            nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            value
        } else {
            nil
        }
    }

    public func value(for key: String) -> JSONValue? {
        objectValue?[key]
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
        kind == .response
    }

    public var requestIDString: String? {
        id?.stringValue
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
            throw CodexProtocolError.malformedJSON("Invalid UTF-8 payload")
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
    case turnStarted = "turn/started"
    case turnCompleted = "turn/completed"
    case threadSuspend = "thread/suspend"
    case commandExecutionRequestApproval = "item/commandExecution/requestApproval"
    case fileChangeRequestApproval = "item/fileChange/requestApproval"
}

public enum CodexApprovalDecision: Equatable, Sendable {
    case approve
    case decline
}

public enum CodexServerRequestKind: String, CaseIterable, Codable, Sendable {
    case commandExecutionRequestApproval = "item/commandExecution/requestApproval"
    case fileChangeRequestApproval = "item/fileChange/requestApproval"

    public static func from(method: String) -> CodexServerRequestKind? {
        switch method {
        case CodexMethod.commandExecutionRequestApproval.rawValue:
            .commandExecutionRequestApproval
        case CodexMethod.fileChangeRequestApproval.rawValue:
            .fileChangeRequestApproval
        default:
            nil
        }
    }
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

public extension CodexPermissionPolicy {
    var jsonValue: JSONValue {
        var value: [String: JSONValue] = [
            "type": .string(type.rawValue),
            "networkAccess": .bool(networkAccess)
        ]

        if let writableRoots {
            value["writableRoots"] = .array(
                writableRoots.map { JSONValue.string($0) }
            )
        }

        return .object(value)
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

public struct CodexModelCapability: Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let isDefault: Bool
    public let defaultReasoningEffort: String?
    public let supportedReasoningEfforts: [String]
    public let metadata: [String: JSONValue]
    public let hidden: Bool

    public init(
        id: String,
        displayName: String,
        isDefault: Bool,
        defaultReasoningEffort: String? = nil,
        supportedReasoningEfforts: [String] = [],
        metadata: [String: JSONValue] = [:],
        hidden: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.metadata = metadata
        self.hidden = hidden
    }

    public init(from object: [String: JSONValue]) throws {
        guard let id = object["id"]?.stringValue else {
            throw CodexProtocolError.missingPayloadField("id")
        }
        guard let displayName = object["displayName"]?.stringValue else {
            throw CodexProtocolError.missingPayloadField("displayName")
        }
        let isDefault = object["isDefault"]?.boolValue ?? false
        let defaultReasoningEffort = object["defaultReasoningEffort"]?.stringValue
        let supportedReasoningEfforts = object["supportedReasoningEfforts"]?.arrayValue?
            .compactMap(\.stringValue) ?? []

        let hidden = object["hidden"]?.boolValue ?? false
        var metadata = object["metadata"]?.objectValue ?? [:]
        let standardKeys: Set<String> = [
            "id",
            "displayName",
            "isDefault",
            "defaultReasoningEffort",
            "supportedReasoningEfforts",
            "hidden",
            "metadata"
        ]
        for (key, value) in object where !standardKeys.contains(key) {
            metadata[key] = value
        }

        self.init(
            id: id,
            displayName: displayName,
            isDefault: isDefault,
            defaultReasoningEffort: defaultReasoningEffort,
            supportedReasoningEfforts: supportedReasoningEfforts,
            metadata: metadata,
            hidden: hidden
        )
    }
}

public struct CodexModelListPage: Equatable, Sendable {
    public let models: [CodexModelCapability]
    public let nextCursor: String?

    public init(models: [CodexModelCapability], nextCursor: String?) {
        self.models = models
        self.nextCursor = nextCursor
    }

    public init(from payload: JSONValue) throws {
        guard let object = payload.objectValue else {
            throw CodexProtocolError.nonObjectPayload(method: "model/list")
        }
        let list = object["models"]?.arrayValue ?? []
        self.models = try list.compactMap { model in
            guard let values = model.objectValue else {
                return nil
            }
            return try CodexModelCapability(from: values)
        }
        self.nextCursor = object["nextCursor"]?.stringValue
    }
}

public enum CodexServerEvent: Equatable, Sendable {
    case turnStarted(threadID: String, turnID: String)
    case turnCompleted(threadID: String, turnID: String)
    case commandExecutionRequestApproval(
        requestID: String,
        turnID: String,
        threadID: String,
        command: String?
    )
    case fileChangeRequestApproval(
        requestID: String,
        turnID: String,
        threadID: String,
        path: String?
    )
    case serverRequest(method: CodexServerRequestKind, requestID: String, payload: JSONValue)
    case notification(method: String, payload: JSONValue)
}

public extension CodexEnvelope {
    func asServerEvent() throws -> CodexServerEvent? {
        guard let method = method else {
            return nil
        }

        let payload = params ?? .null
        let obj = payload.objectValue ?? [:]

        switch method {
        case CodexMethod.turnStarted.rawValue:
            guard let threadID = obj["threadId"]?.stringValue else {
                throw CodexProtocolError.missingPayloadField("threadId")
            }
            guard let turnID = obj["turnId"]?.stringValue else {
                throw CodexProtocolError.missingPayloadField("turnId")
            }
            return .turnStarted(threadID: threadID, turnID: turnID)

        case CodexMethod.turnCompleted.rawValue:
            guard let threadID = obj["threadId"]?.stringValue else {
                throw CodexProtocolError.missingPayloadField("threadId")
            }
            guard let turnID = obj["turnId"]?.stringValue else {
                throw CodexProtocolError.missingPayloadField("turnId")
            }
            return .turnCompleted(threadID: threadID, turnID: turnID)

        case CodexMethod.commandExecutionRequestApproval.rawValue,
             CodexMethod.fileChangeRequestApproval.rawValue:
            guard let requestID = id?.stringValue else {
                throw CodexProtocolError.missingPayloadField("id")
            }
            guard let threadID = obj["threadId"]?.stringValue ?? obj["threadID"]?.stringValue else {
                throw CodexProtocolError.missingPayloadField("threadId")
            }
            guard let turnID = obj["turnId"]?.stringValue ?? obj["turnID"]?.stringValue else {
                throw CodexProtocolError.missingPayloadField("turnId")
            }
            if let kind = CodexServerRequestKind.from(method: method) {
                switch kind {
                case .commandExecutionRequestApproval:
                    let command = obj["command"]?.stringValue
                    return .commandExecutionRequestApproval(
                        requestID: requestID,
                        turnID: turnID,
                        threadID: threadID,
                        command: command
                    )
                case .fileChangeRequestApproval:
                    let path = obj["path"]?.stringValue
                    return .fileChangeRequestApproval(
                        requestID: requestID,
                        turnID: turnID,
                        threadID: threadID,
                        path: path
                    )
                }
            }
            return .serverRequest(method: .commandExecutionRequestApproval, requestID: requestID, payload: payload)

        default:
            return .notification(method: method, payload: payload)
        }
    }
}

public enum CodexLogSanitizer {
    public static let replacement = "[REDACTED]"

    public static func sanitize(_ text: String) -> String {
        var output = text

        output = redact(pattern: "(?i)(token|access[_-]?token|api[_-]?key|secret|password|passwd|authorization|auth|bearer)\\s*[:=]\\s*[^\\s\\n]+", in: output)
        output = redact(pattern: "\\b[A-Z_][A-Z0-9_]*=([^\\s]+)", in: output)
        output = redact(pattern: "--(token|password|key)\\s+[^\"\\s]+", in: output)
        output = redact(pattern: "(?i)(prompt|env|environment)\\s*[:=]\\s*['\"]?[^\"'\n]+['\"]?", in: output)
        return output
    }

    private static func redact(pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
