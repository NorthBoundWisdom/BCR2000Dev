import Foundation

/// Client-neutral tool execution. Transport credentials never enter this service or its log.
@MainActor
public final class AgentControlService {
    public let session: SurfaceSession
    public var permissions: MCPPermissions
    public private(set) var audit: [MCPAuditEntry] = []
    public var onChange: (@MainActor () -> Void)?
    private let now: @MainActor () -> Date
    private var rateWindow: Date?
    private var usedWrites = 0

    public init(session: SurfaceSession, permissions: MCPPermissions = MCPPermissions(),
                now: @escaping @MainActor () -> Date = { .now }) {
        self.session = session
        self.permissions = permissions
        self.now = now
    }

    public func record(_ method: String, succeeded: Bool, detail: String) {
        audit.append(MCPAuditEntry(time: now(), method: method, succeeded: succeeded, detail: detail))
        if audit.count > 100 { audit.removeFirst(audit.count - 100) }
        onChange?()
    }

    public func call(_ name: String, arguments: JSONValue = .object([:])) -> MCPToolResult {
        do {
            guard MCPToolCatalog.names.contains(name) else { throw MCPToolFailure("未知工具") }
            guard let args = arguments.objectValue else { throw MCPToolFailure("arguments 必须是对象") }
            try validateArguments(args, tool: name)
            let result = try execute(name, args)
            record(name, succeeded: true, detail: "完成")
            return MCPToolResult(value: result, isError: false)
        } catch {
            // Error messages only include domain validation details, never HTTP headers or tokens.
            record(name, succeeded: false, detail: error.localizedDescription)
            return MCPToolResult(value: .object(["error": .string(error.localizedDescription)]), isError: true)
        }
    }

    private func execute(_ name: String, _ args: [String: JSONValue]) throws -> JSONValue {
        switch name {
        case "get_status":
            return .object([
                "source": .string(session.source.rawValue),
                "connected": .bool(session.source == .mock || session.connection.isConnected),
                "droppedFeedbackCount": .number(session.droppedFeedbackCount),
                "permissions": try .encoded(permissions),
                "ledSource": .string(session.engine.ledFeedbackSource.rawValue),
                "motionSafety": motionSafetyInfo(),
                "hardwareConnection": .object([
                    "connected": .bool(session.connection.isConnected),
                    "source": session.connection.connectedSource.map(JSONValue.string) ?? .null,
                    "destination": session.connection.connectedDestination.map(JSONValue.string) ?? .null,
                    "error": session.connection.lastError.map(JSONValue.string) ?? .null,
                ]),
                "configurationPersistenceError": session.lastConfigurationPersistenceError.map(JSONValue.string) ?? .null,
            ])
        case "list_parameters":
            return .array(try session.engine.configuration.parameters.map { try parameterInfo($0.id) })
        case "get_parameter":
            return try parameterInfo(ParameterID(string(args, "id")))
        case "set_parameter":
            return try write([(ParameterID(string(args, "id")), number(args, "value"))])[0]
        case "nudge_parameter":
            let id = ParameterID(try string(args, "id"))
            guard let value = session.engine.value(of: id) else { throw MCPToolFailure("未知参数：\(id)") }
            let next = value + (try number(args, "delta"))
            guard next.isFinite else { throw MCPToolFailure("增量结果必须是有限数值") }
            return try write([(id, next)])[0]
        case "set_parameters":
            guard case let .array(values) = args["values"], !values.isEmpty, values.count <= 256 else {
                throw MCPToolFailure("values 必须包含 1–256 个参数")
            }
            let entries: [(ParameterID, Double)] = try values.map { entry in
                guard let entry = entry.objectValue, Set(entry.keys) == ["id", "value"] else {
                    throw MCPToolFailure("每条批量写入必须只包含 id 和 value")
                }
                return (ParameterID(try string(entry, "id")), try number(entry, "value"))
            }
            return .array(try write(entries))
        case "reset_group":
            let group = try string(args, "group")
            let parameters = session.engine.configuration.parameters.filter { $0.group == group }
            guard !parameters.isEmpty else { throw MCPToolFailure("未知参数组") }
            let writable = parameters.filter { $0.agentWritable && !session.isMCPProtectedParameter($0.id) }
            let skipped = parameters.filter { !$0.agentWritable || session.isMCPProtectedParameter($0.id) }
            return .object([
                "results": .array(try write(writable.map { ($0.id, $0.defaultValue) })),
                "skipped": .array(skipped.map { .object(["id": .string($0.id.rawValue),
                    "reason": .string("参数受保护，不允许 Agent 写入")]) }),
            ])
        case "list_controls":
            return .array(try BCRLayout.allControls.map { control in
                .object([
                    "control": try .encoded(control),
                    "label": .string(control.shortName),
                    "assignment": try session.engine.configuration.assignment(for: control).map(JSONValue.encoded) ?? .null,
                    "binding": try session.engine.hardwareMap.midi(for: control).map(JSONValue.encoded) ?? .null,
                    "value": .number(Int(session.source == .mock ? session.mock.value(of: control) : session.engine.state(of: control).value)),
                ])
            })
        case "assign_control":
            try requireConfigurationWrite()
            let assignment = try args["assignment"]!.decoded(ControlAssignment.self)
            if case let .agentPrimaryAction(slot) = assignment.target, !(1...8).contains(slot.rawValue) {
                throw MCPToolFailure("Agent 槽位必须为 1–8")
            }
            if case let .resetGroup(group) = assignment.target,
               !session.engine.configuration.parameterGroups.contains(group) { throw MCPToolFailure("未知参数组") }
            // Validate without effects before consuming rate allowance or changing session state.
            var candidate = session.engine.configuration
            try candidate.assign(assignment)
            try consumeWrites(1)
            try session.withWriteOrigin(.agent) { try session.setAssignment(assignment, for: assignment.control) }
            try requireSavedConfiguration()
            return try .encoded(assignment)
        case "create_parameter", "update_parameter":
            try requireConfigurationWrite()
            let definition = try args["definition"]!.decoded(ParameterDefinition.self)
            try definition.validate()
            guard !session.isMCPProtectedParameter(definition.id) else {
                throw MCPToolFailure("MCP 不允许修改使能参数定义：\(definition.id)")
            }
            if name == "update_parameter", let previous = session.engine.configuration.parameter(definition.id) {
                guard previous.agentWritable else { throw MCPToolFailure("MCP 不允许修改不可写参数定义：\(definition.id)") }
                guard previous.agentWritable == definition.agentWritable else {
                    throw MCPToolFailure("MCP 不允许修改 agentWritable")
                }
            }
            guard definition.defaultValue.isFinite,
                  (definition.minimum...definition.maximum).contains(definition.defaultValue) else {
                throw MCPToolFailure("默认值必须在参数范围内")
            }
            var candidate = session.engine.configuration
            if name == "create_parameter" { try candidate.addParameter(definition) }
            else { try candidate.updateParameter(definition) }
            try consumeWrites(1)
            try session.withWriteOrigin(.agent) {
                if name == "create_parameter" { try session.addParameter(definition) }
                else { try session.updateParameter(definition) }
            }
            try requireSavedConfiguration()
            return try parameterInfo(definition.id)
        default: throw MCPToolFailure("未知工具")
        }
    }

    private func write(_ entries: [(ParameterID, Double)]) throws -> [JSONValue] {
        guard permissions.parameterWrite else { throw MCPToolFailure("未开启参数写入权限") }
        var seen = Set<ParameterID>()
        for (id, value) in entries {
            guard value.isFinite else { throw MCPToolFailure("参数值必须是有限数值") }
            guard seen.insert(id).inserted else { throw MCPToolFailure("批量写入包含重复参数：\(id)") }
            guard let definition = session.engine.configuration.parameter(id) else { throw MCPToolFailure("未知参数：\(id)") }
            guard definition.agentWritable, !session.isMCPProtectedParameter(id) else { throw MCPToolFailure("参数不允许 Agent 写入：\(id)") }
        }
        try consumeWrites(entries.count)
        // All validation completes before the first synchronous effect. No await can interleave a change.
        return session.withWriteOrigin(.agent) {
            entries.map { id, requested in
                session.setParameter(id, to: requested)
                let actual = session.engine.value(of: id)!
                return .object(["id": .string(id.rawValue), "value": .double(actual),
                                "clamped": .bool(actual != requested)])
            }
        }
    }

    private func parameterInfo(_ id: ParameterID) throws -> JSONValue {
        guard let definition = session.engine.configuration.parameter(id),
              let value = session.engine.value(of: id),
              case var .object(info) = try JSONValue.encoded(definition) else {
            throw MCPToolFailure("未知参数：\(id)")
        }
        info["value"] = .double(value)
        info["actualValue"] = session.engine.actualFeedbackValues[id].map(JSONValue.double) ?? .null
        info["outputValue"] = session.motionSafety?.outputs[id].map(JSONValue.double) ?? .null
        info["writable"] = .bool(permissions.parameterWrite && definition.agentWritable && !session.isMCPProtectedParameter(id))
        info["controls"] = .array(try session.engine.configuration.controls(targetingParameter: id).map(JSONValue.encoded))
        return .object(info)
    }

    private func motionSafetyInfo() -> JSONValue {
        guard let safety = session.motionSafety else { return .null }
        func values(_ input: [ParameterID: Double]) -> JSONValue {
            .object(Dictionary(uniqueKeysWithValues: input.map { ($0.key.rawValue, .double($0.value)) }))
        }
        return .object(["status": .string(safety.status.rawValue), "reason": .string(safety.reason),
                        "limited": .bool(safety.limited), "outputs": values(safety.outputs), "actual": values(safety.actual),
                        "baseline": values(safety.baseline)])
    }

    private func requireSavedConfiguration() throws {
        if let error = session.lastConfigurationPersistenceError {
            throw MCPToolFailure("配置已在内存更新，但持久化失败：\(error)")
        }
    }

    private func requireConfigurationWrite() throws {
        guard permissions.parameterWrite, permissions.configurationWrite else { throw MCPToolFailure("未开启配置写入权限") }
    }

    private func consumeWrites(_ count: Int) throws {
        let time = now()
        if rateWindow == nil || time < rateWindow! || time.timeIntervalSince(rateWindow!) >= 1 {
            rateWindow = time
            usedWrites = 0
        }
        guard permissions.writesPerSecond > 0,
              count <= permissions.writesPerSecond - usedWrites else { throw MCPToolFailure("写入超过每秒限额") }
        usedWrites += count
    }

    private func validateArguments(_ args: [String: JSONValue], tool: String) throws {
        try MCPInputValidation.validate(.object(args), schema: MCPToolCatalog.inputSchema(for: tool))
    }

    private func string(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue, value.utf8.count <= 1_024 else { throw MCPToolFailure("\(key) 必须是长度不超过 1024 的字符串") }
        return value
    }

    private func number(_ args: [String: JSONValue], _ key: String) throws -> Double {
        guard let value = args[key]?.finiteNumber else { throw MCPToolFailure("\(key) 必须是有限数值") }
        return value
    }
}
