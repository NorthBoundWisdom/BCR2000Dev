import Foundation

public enum MCPVersions {
    public static let current = "2026-07-28"
    public static let legacy = "2025-11-25"
    public static let supported = [current, legacy]
}

public extension JSONValue {
    var finiteNumber: Double? {
        let value: Double
        switch self {
        case let .number(n): value = Double(n)
        case let .double(n): value = n
        default: return nil
        }
        return value.isFinite ? value : nil
    }

    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    var jsonText: String {
        // All values admitted by the service are finite and therefore JSON encodable.
        get throws { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    }
}

public struct MCPPermissions: Codable, Equatable, Sendable {
    public var parameterWrite: Bool
    public var configurationWrite: Bool
    public var writesPerSecond: Int

    public init(parameterWrite: Bool = true, configurationWrite: Bool = false, writesPerSecond: Int = 60) {
        self.parameterWrite = parameterWrite
        self.configurationWrite = configurationWrite
        self.writesPerSecond = writesPerSecond
    }
}

public struct MCPAuditEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let time: Date
    public let method: String
    public let succeeded: Bool
    public let detail: String

    public init(time: Date, method: String, succeeded: Bool, detail: String) {
        id = UUID()
        self.time = time
        self.method = method
        self.succeeded = succeeded
        self.detail = detail
    }
}

public struct MCPToolFailure: Error, LocalizedError, Equatable, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }

    public init(_ reason: String) { self.reason = reason }
}

public struct MCPToolResult: Equatable, Sendable {
    public let value: JSONValue
    public let isError: Bool

    public var rpcValue: JSONValue {
        get throws {
            .object([
                "content": .array([.object(["type": .string("text"), "text": .string(try JSONValue.object(["data": value]).jsonText)])]),
                "structuredContent": .object(["data": value]),
                "isError": .bool(isError),
            ])
        }
    }
}

public enum MCPToolCatalog {
    private static let string: JSONValue = .object(["type": .string("string")])
    private static let number: JSONValue = .object(["type": .string("number")])
    private static let boolean: JSONValue = .object(["type": .string("boolean")])
    private static let parameterDefinition: JSONValue = schema([
        "id": string, "name": string, "group": string, "unit": string,
        "minimum": number, "maximum": number, "defaultValue": number,
        "kind": .object(["type": .string("string"), "enum": .array([.string("continuous"), .string("toggle")])]),
        "agentWritable": boolean,
        "step": .object(["oneOf": .array([
            .object(["type": .string("number"), "exclusiveMinimum": .number(0)]),
            .object(["type": .string("null")]),
        ])]),
    ], required: ["id", "name"])
    private static let control: JSONValue = .object(["oneOf": .array(BCRSection.allCases.map { section in
        schema([
            "section": .object(["const": .string(section.rawValue)]),
            "row": .object(["type": .string("integer"), "minimum": .number(section.rowRange.lowerBound), "maximum": .number(section.rowRange.upperBound)]),
            "index": .object(["type": .string("integer"), "minimum": .number(section.indexRange.lowerBound), "maximum": .number(section.indexRange.upperBound)]),
        ], required: ["section", "row", "index"])
    })])
    private static let assignment: JSONValue = schema([
        "control": control,
        "target": .object(["oneOf": .array([
            schema(["parameter": schema(["_0": string], required: ["_0"])], required: ["parameter"]),
            schema(["agentPrimaryAction": schema(["_0": schema(["rawValue": .object([
                "type": .string("integer"), "minimum": .number(1), "maximum": .number(8),
            ])], required: ["rawValue"])], required: ["_0"])], required: ["agentPrimaryAction"]),
            schema(["resetGroup": schema(["_0": string], required: ["_0"])], required: ["resetGroup"]),
            schema(["stepParameter": schema(["id": string, "step": number, "wraps": boolean], required: ["id", "step", "wraps"])], required: ["stepParameter"]),
            schema(["setParameter": schema(["id": string, "value": number], required: ["id", "value"])], required: ["setParameter"]),
            schema(["cycleParameter": schema(["id": string, "values": .object([
                "type": .string("array"), "items": number, "minItems": .number(1), "maxItems": .number(256),
            ])], required: ["id", "values"])], required: ["cycleParameter"]),
        ])]),
        "buttonBehavior": .object(["type": .string("string"), "enum": .array([.string("toggle"), .string("momentary")])]),
        "inverted": boolean,
        "encoderMode": .object(["type": .string("string"), "enum": .array(EncoderMode.allCases.map { .string($0.rawValue) })]),
        "encoderStep": .object(["type": .string("number"), "exclusiveMinimum": .number(0)]),
    ], required: ["control", "target", "buttonBehavior", "inverted"])

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    public static let names = [
        "get_status", "list_parameters", "get_parameter", "set_parameter", "set_parameters",
        "nudge_parameter", "reset_group", "list_controls", "assign_control", "create_parameter", "update_parameter",
    ]

    public static func inputSchema(for name: String) -> JSONValue {
        switch name {
        case "get_status", "list_parameters", "list_controls": schema([:])
        case "get_parameter": schema(["id": string], required: ["id"])
        case "set_parameter": schema(["id": string, "value": number], required: ["id", "value"])
        case "set_parameters":
            schema(["values": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(256),
                                      "items": schema(["id": string, "value": number], required: ["id", "value"])])], required: ["values"])
        case "nudge_parameter": schema(["id": string, "delta": number], required: ["id", "delta"])
        case "reset_group": schema(["group": string], required: ["group"])
        case "assign_control": schema(["assignment": assignment], required: ["assignment"])
        case "create_parameter", "update_parameter": schema(["definition": parameterDefinition], required: ["definition"])
        default: schema([:])
        }
    }

    public static var tools: [JSONValue] {
        names.map { name in
            .object([
                "name": .string(name),
                "description": .string(descriptions[name] ?? name),
                "inputSchema": inputSchema(for: name),
                "outputSchema": .object(["type": .string("object"), "properties": .object(["data": .object([:])]),
                                         "required": .array([.string("data")])]),
                "annotations": .object(["readOnlyHint": .bool(name.hasPrefix("get_") || name.hasPrefix("list_")),
                                         "openWorldHint": .bool(false)]),
            ])
        }
    }

    private static let descriptions = [
        "get_status": "读取设备连接、反馈丢弃计数与 MCP 权限。",
        "list_parameters": "列出参数定义、当前值、Agent 写入权限与绑定控件。",
        "get_parameter": "读取一个参数的定义与当前值。",
        "set_parameter": "写入参数并同步所有绑定 LED；报告实际值与 clamp。",
        "set_parameters": "原子批量写入；任一参数校验失败则全部不写。",
        "nudge_parameter": "按增量修改一个参数。",
        "reset_group": "复位组内可写参数，返回 results 和受保护参数的 skipped 列表。",
        "list_controls": "列出物理控件、功能分配、MIDI 绑定与当前值。",
        "assign_control": "修改控件分配，需要配置写入权限。",
        "create_parameter": "创建参数，需要配置写入权限。",
        "update_parameter": "更新参数定义，需要配置写入权限。",
    ]
}
