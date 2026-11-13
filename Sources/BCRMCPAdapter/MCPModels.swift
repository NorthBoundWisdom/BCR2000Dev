import BCRSurfaceDomain
import BCRFoundation
import Foundation

public enum MCPVersions {
    public static let current = "2026-07-28"
    public static let legacy = "2025-11-25"
    public static let supported = [current, legacy]
}

public struct MCPPermissions: Codable, Equatable, Sendable {
    public var parameterWrite: Bool
    public var configurationWrite: Bool
    public var agentControl: Bool
    public var deviceControl: Bool
    public var robotControl: Bool
    public var chassisControl: Bool
    public var simulationControl: Bool
    public var writesPerSecond: Int

    public init(parameterWrite: Bool = true, configurationWrite: Bool = false, writesPerSecond: Int = 60,
                agentControl: Bool = false, deviceControl: Bool = false,
                robotControl: Bool = false, chassisControl: Bool = false, simulationControl: Bool = false)
    {
        self.parameterWrite = parameterWrite
        self.configurationWrite = configurationWrite
        self.writesPerSecond = writesPerSecond
        self.agentControl = agentControl
        self.deviceControl = deviceControl
        self.robotControl = robotControl; self.chassisControl = chassisControl; self
            .simulationControl = simulationControl
    }

    private enum CodingKeys: String,
        CodingKey
    { case parameterWrite, configurationWrite, writesPerSecond, agentControl, deviceControl, robotControl,
           chassisControl, simulationControl
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parameterWrite = try c.decode(Bool.self, forKey: .parameterWrite)
        configurationWrite = try c.decode(Bool.self, forKey: .configurationWrite)
        writesPerSecond = try c.decode(Int.self, forKey: .writesPerSecond)
        agentControl = c.contains(.agentControl) ? try c.decode(Bool.self, forKey: .agentControl) : false
        deviceControl = c.contains(.deviceControl) ? try c.decode(Bool.self, forKey: .deviceControl) : false
        robotControl = try c.decodeIfPresent(Bool.self, forKey: .robotControl) ?? false
        chassisControl = try c.decodeIfPresent(Bool.self, forKey: .chassisControl) ?? false
        simulationControl = try c.decodeIfPresent(Bool.self, forKey: .simulationControl) ?? false
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
    public let rawObject: Bool
    public init(value: JSONValue, isError: Bool, rawObject: Bool = false) {
        self.value = value; self.isError = isError; self.rawObject = rawObject
    }

    public var rpcValue: JSONValue {
        get throws {
            let content = rawObject ? value : .object(["data": value])
            return .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(try content.jsonText)
                ])]),
                "structuredContent": content,
                "isError": .bool(isError)
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
        "agentWritable": boolean, "externallyProtected": boolean,
        "step": .object(["oneOf": .array([
            .object(["type": .string("number"), "exclusiveMinimum": .number(0)]),
            .object(["type": .string("null")])
        ])])
    ], required: ["id", "name"])
    private static let control: JSONValue = .object(["oneOf": .array(BCRSection.allCases.map { section in
        schema([
            "section": .object(["const": .string(section.rawValue)]),
            "row": .object([
                "type": .string("integer"),
                "minimum": .number(section.rowRange.lowerBound),
                "maximum": .number(section.rowRange.upperBound)
            ]),
            "index": .object([
                "type": .string("integer"),
                "minimum": .number(section.indexRange.lowerBound),
                "maximum": .number(section.indexRange.upperBound)
            ])
        ], required: ["section", "row", "index"])
    })])
    private static let assignment: JSONValue = schema([
        "control": control,
        "target": .object(["oneOf": .array([
            schema(["parameter": schema(["_0": string], required: ["_0"])], required: ["parameter"]),
            schema(["agentPrimaryAction": schema(["_0": schema(["rawValue": .object([
                "type": .string("integer"), "minimum": .number(1), "maximum": .number(8)
            ])], required: ["rawValue"])], required: ["_0"])], required: ["agentPrimaryAction"]),
            schema(["switchPage": schema(["_0": string], required: ["_0"])], required: ["switchPage"]),
            schema(["runMacro": schema(["_0": string], required: ["_0"])], required: ["runMacro"]),
            schema(["resetGroup": schema(["_0": string], required: ["_0"])], required: ["resetGroup"]),
            schema(
                ["stepParameter": schema(
                    ["id": string, "step": number, "wraps": boolean],
                    required: ["id", "step", "wraps"]
                )],
                required: ["stepParameter"]
            ),
            schema(
                ["setParameter": schema(["id": string, "value": number], required: ["id", "value"])],
                required: ["setParameter"]
            ),
            schema(["cycleParameter": schema(["id": string, "values": .object([
                "type": .string("array"), "items": number, "minItems": .number(1), "maxItems": .number(256)
            ])], required: ["id", "values"])], required: ["cycleParameter"])
        ])]),
        "buttonBehavior": .object([
            "type": .string("string"),
            "enum": .array([.string("toggle"), .string("momentary")])
        ]),
        "inverted": boolean,
        "encoderMode": .object([
            "type": .string("string"),
            "enum": .array(EncoderMode.allCases.map { .string($0.rawValue) })
        ]),
        "encoderStep": .object(["type": .string("number"), "exclusiveMinimum": .number(0)])
    ], required: ["control", "target", "buttonBehavior", "inverted"])

    private static let endpointID: JSONValue = .object(["oneOf": .array([
        .object(["type": .string("integer")]), .object(["type": .string("null")])
    ])])

    public static let presetAlignmentOptionNames = [
        "completeButtons", "ringModes", "buttonBehavior", "lockPreset", "enableButtonFunctions"
    ]

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    public static let names = [
        "get_status", "list_parameters", "get_parameter", "set_parameter", "set_parameters",
        "nudge_parameter", "reset_group", "list_controls", "assign_control", "create_parameter", "update_parameter",
        "get_agents", "start_agent", "interrupt_agent", "stop_all_agents", "set_device_source",
        "begin_control_learn", "stop_control_learn", "restrict_configuration_write",
        "list_midi_endpoints", "set_midi_endpoints",
        "get_preset_alignment", "preview_preset_alignment", "apply_preset_alignment", "restore_preset",
        "dismiss_preset_alignment"
    ]

    public static func inputSchema(for name: String) -> JSONValue {
        switch name {
        case "get_status", "list_parameters", "list_controls", "get_agents", "stop_all_agents", "stop_control_learn",
             "restrict_configuration_write", "list_midi_endpoints", "get_preset_alignment", "apply_preset_alignment",
             "restore_preset", "dismiss_preset_alignment": schema([:])
        case "preview_preset_alignment":
            // Omitted options keep the alignment window's defaults.
            schema(Dictionary(uniqueKeysWithValues: presetAlignmentOptionNames.map { ($0, boolean) }))
        case "set_midi_endpoints":
            // null selects the automatic "BCR2000 Port 1" policy for that direction.
            schema(["sourceID": endpointID, "destinationID": endpointID], required: ["sourceID", "destinationID"])
        case "start_agent", "interrupt_agent": schema(
                ["slot": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(8)])],
                required: ["slot"]
            )
        case "set_device_source": schema(
                ["source": .object([
                    "type": .string("string"),
                    "enum": .array([.string("mock"), .string("hardware")])
                ])],
                required: ["source"]
            )
        case "begin_control_learn": schema(["control": control], required: ["control"])
        case "get_parameter": schema(["id": string], required: ["id"])
        case "set_parameter": schema(["id": string, "value": number], required: ["id", "value"])
        case "set_parameters":
            schema(["values": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(256),
                                       "items": schema(["id": string, "value": number], required: ["id", "value"])])],
            required: ["values"])
        case "nudge_parameter": schema(["id": string, "delta": number], required: ["id", "delta"])
        case "reset_group": schema(["group": string], required: ["group"])
        case "assign_control": schema(["assignment": assignment], required: ["assignment"])
        case "create_parameter", "update_parameter": schema(
                ["definition": parameterDefinition],
                required: ["definition"]
            )
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
                                        "openWorldHint": .bool(name == "start_agent")])
            ])
        }
    }

    private static let descriptions = [
        "get_status": L10n.text("读取设备连接、反馈丢弃计数与 MCP 权限。"),
        "list_parameters": L10n.text("列出参数定义、当前值、Agent 写入权限与绑定控件。"),
        "get_parameter": L10n.text("读取一个参数的定义与当前值。"),
        "set_parameter": L10n.text("写入参数并同步所有绑定 LED；报告实际值与 clamp。"),
        "set_parameters": L10n.text("原子批量写入；任一参数校验失败则全部不写。"),
        "nudge_parameter": L10n.text("按增量修改一个参数。"),
        "reset_group": L10n.text("复位组内可写参数，返回 results 和受保护参数的 skipped 列表。"),
        "list_controls": L10n.text("列出物理控件、功能分配、MIDI 绑定与当前值。"),
        "assign_control": L10n.text("修改控件分配，需要配置写入权限。"),
        "create_parameter": L10n.text("创建参数，需要配置写入权限。"),
        "update_parameter": L10n.text("更新参数定义，需要配置写入权限。"),
        "set_device_source": L10n.text("切换设备源，需要设备切换权限且外部输出已停止。"),
        "begin_control_learn": L10n.text("等待实体输入学习未绑定控件，不覆盖已有映射。"),
        "stop_control_learn": L10n.text("停止控件学习，需要配置写入权限。"),
        "restrict_configuration_write": L10n.text("关闭配置写入权限并持久化，不能通过 MCP 再次开启。"),
        "list_midi_endpoints": L10n.text("列出可用的实体 MIDI 输入/输出端口、当前选择与实际连接。"),
        "set_midi_endpoints": L10n.text("选择实体 MIDI 输入/输出端口并保存；null 为自动 Port 1，需要设备切换权限且外部输出已停止。"),
        "get_preset_alignment": L10n.text("读取设备预设对齐的阶段、进度、计划变更与恢复可用性。"),
        "preview_preset_alignment": L10n.text("读取设备临时预设并生成对齐预览，不写设备；需要设备切换与配置写入权限。"),
        "apply_preset_alignment": L10n.text("把当前预览写入设备临时预设并回读校验，不写永久存储；需要设备切换与配置写入权限。"),
        "restore_preset": L10n.text("回读核对后恢复对齐前的设备临时预设和映射；需要设备切换与配置写入权限。"),
        "dismiss_preset_alignment": L10n.text("关闭空闲的预设对齐窗口，不写设备。")
    ]
}
