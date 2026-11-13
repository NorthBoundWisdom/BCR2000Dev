import BCRFoundation
import BCRSurfaceDomain
import Foundation

/// The console adapter owns console policies and tools; it never operates an Agent backend.
public enum SurfaceMCPModule {
    public static var names: [String] { MCPToolCatalog.names.filter { !AgentMCPModule.names.contains($0) } }
}

extension AgentControlService {
    func executeSurface(_ name: String, _ args: [String: JSONValue]) throws -> JSONValue {
        switch name {
        case "set_device_source":
            guard permissions.parameterWrite,
                  permissions.deviceControl else { throw MCPToolFailure(L10n.text("未开启设备切换权限")) }
            guard let source = DeviceSource(rawValue: try string(args, "source")), let onSelectSource else {
                throw MCPToolFailure(L10n.text("设备切换服务不可用"))
            }
            try consumeWrites(1)
            try requireInactiveOutput()
            guard session.engine.learnTarget == nil else { throw MCPToolFailure(L10n.text("请先停止控件学习")) }
            if source == .hardware { try requireHardwareConnection() }
            try onSelectSource(source)
            return .object(["source": .string(session.source.rawValue)])
        case "list_midi_endpoints":
            let connection = session.connection
            func list(_ endpoints: [MIDIEndpointDescriptor]) -> JSONValue {
                .array(endpoints.map { .object([
                    "id": .number(Int($0.id)), "name": .string($0.name),
                    "availabilityKnown": .bool($0.availabilityKnown)
                ]) })
            }
            return .object([
                "sources": list(connection.sourceEndpoints),
                "destinations": list(connection.destinationEndpoints),
                "selection": onReadMIDIEndpointSelection.map { endpointSelectionInfo($0()) } ?? .null,
                "connectedSourceID": connection.connectedSourceID.map { .number(Int($0)) } ?? .null,
                "connectedDestinationID": connection.connectedDestinationID.map { .number(Int($0)) } ?? .null,
                "connectedSource": connection.connectedSource.map(JSONValue.string) ?? .null,
                "connectedDestination": connection.connectedDestination.map(JSONValue.string) ?? .null,
                "error": connection.lastError.map(JSONValue.string) ?? .null
            ])
        case "set_midi_endpoints":
            guard permissions.parameterWrite,
                  permissions.deviceControl else { throw MCPToolFailure(L10n.text("未开启设备切换权限")) }
            guard let onSelectMIDIEndpoints else { throw MCPToolFailure(L10n.text("MIDI 端口设置服务不可用")) }
            func endpoint(_ key: String, in available: [MIDIEndpointDescriptor]) throws -> Int32? {
                guard let value = args[key], value != .null else { return nil }
                guard let id = value.exactIntValue.flatMap(Int32.init(exactly:)),
                      available.contains(where: { $0.id == id })
                else { throw MCPToolFailure(L10n.text("所选 MIDI 端口不存在，请先用 list_midi_endpoints 读取")) }
                return id
            }
            let selection = MIDIEndpointSelection(
                sourceID: try endpoint("sourceID", in: session.connection.sourceEndpoints),
                destinationID: try endpoint("destinationID", in: session.connection.destinationEndpoints)
            )
            try selection.validate()
            try consumeWrites(1)
            try requireInactiveOutput()
            guard session.engine.learnTarget == nil else { throw MCPToolFailure(L10n.text("请先停止控件学习")) }
            try onSelectMIDIEndpoints(selection)
            return endpointSelectionInfo(selection)
        case "get_status":
            return .object([
                "source": .string(session.source.rawValue),
                "activePage": .string(session.engine.configuration.activePageID ?? SurfaceConfiguration.basePageID),
                "connected": .bool(session.source == .mock || session.connection.isConnected),
                "droppedFeedbackCount": .number(session.droppedFeedbackCount),
                "permissions": try .encoded(permissions),
                "ledSource": .string(session.engine.ledFeedbackSource.rawValue),
                "learningControl": try session.engine.learnTarget.map(JSONValue.encoded) ?? .null,
                "input_generation": .string(session.inputEvents.generation),
                "diagnostic_readback": .bool(session.diagnosticReadbackActive),
                "pending_feedback_count": .number(session.pendingFeedbackCount),
                "motionSafety": motionSafetyInfo(),
                "hardwareConnection": .object([
                    "confirmation": .string((onReadHardwareConnectionConfirmation?() ?? .none).rawValue),
                    "connected": .bool(session.connection.isConnected),
                    "source": session.connection.connectedSource.map(JSONValue.string) ?? .null,
                    "destination": session.connection.connectedDestination.map(JSONValue.string) ?? .null,
                    "error": session.connection.lastError.map(JSONValue.string) ?? .null
                ]),
                "configurationPersistenceError": session.lastConfigurationPersistenceError
                    .map(JSONValue.string) ?? .null
            ])
        case "list_parameters":
            return .array(try session.engine.configuration.parameters.map { try parameterInfo($0.id) })
        case "get_parameter":
            return try parameterInfo(ParameterID(string(args, "id")))
        case "set_parameter":
            return try write([(ParameterID(string(args, "id")), number(args, "value"))])[0]
        case "nudge_parameter":
            let id = ParameterID(try string(args, "id"))
            guard let value = session.engine.value(of: id) else { throw MCPToolFailure(L10n.text("未知参数：\(id)")) }
            let next = value + (try number(args, "delta"))
            guard next.isFinite else { throw MCPToolFailure(L10n.text("增量结果必须是有限数值")) }
            return try write([(id, next)])[0]
        case "set_parameters":
            guard case let .array(values) = args["values"], !values.isEmpty, values.count <= 256 else {
                throw MCPToolFailure(L10n.text("values 必须包含 1–256 个参数"))
            }
            let entries: [(ParameterID, Double)] = try values.map { entry in
                guard let entry = entry.objectValue, Set(entry.keys) == ["id", "value"] else {
                    throw MCPToolFailure(L10n.text("每条批量写入必须只包含 id 和 value"))
                }
                return (ParameterID(try string(entry, "id")), try number(entry, "value"))
            }
            return .array(try write(entries))
        case "reset_group":
            let group = try string(args, "group")
            let parameters = session.engine.configuration.parameters.filter { $0.group == group }
            guard !parameters.isEmpty else { throw MCPToolFailure(L10n.text("未知参数组")) }
            let writable = parameters.filter { $0.agentWritable && !session.isMCPProtectedParameter($0.id) }
            let skipped = parameters.filter { !$0.agentWritable || session.isMCPProtectedParameter($0.id) }
            return .object([
                "results": .array(try write(writable.map { ($0.id, $0.defaultValue) })),
                "skipped": .array(skipped.map { .object(["id": .string($0.id.rawValue),
                                                         "reason": .string(L10n.text("参数受保护，不允许 Agent 写入"))]) })
            ])
        case "list_controls":
            return .array(try BCRLayout.allControls.map { control in
                .object([
                    "control": try .encoded(control),
                    "label": .string(control.shortName),
                    "assignment": try session.engine.configuration.assignment(for: control)
                        .map(JSONValue.encoded) ?? .null,
                    "binding": try session.engine.hardwareMap.midi(for: control).map(JSONValue.encoded) ?? .null,
                    "value": .number(Int(session.source == .mock ? session.mock.value(of: control) : session.engine
                            .state(of: control).value))
                ])
            })
        case "begin_control_learn":
            try requireConfigurationWrite()
            try requireInactiveOutput()
            try requireHardwareConnection()
            guard session.source == .hardware else { throw MCPToolFailure(L10n.text("控件学习需要实体设备源")) }
            guard session.engine.learnTarget == nil else { throw MCPToolFailure(L10n.text("请先停止控件学习")) }
            let control = try args["control"]!.decoded(BCRControlID.self)
            guard session.engine.hardwareMap.midi(for: control) == nil else {
                throw MCPToolFailure(L10n.text("控件已有学习映射，不能由 MCP 覆盖"))
            }
            try consumeWrites(1)
            guard session.beginLearning(at: control) else { throw MCPToolFailure(L10n.text("控件学习需要实体设备源")) }
            return .object(["control": try .encoded(control), "waitingForHardwareInput": .bool(true)])
        case "stop_control_learn":
            try requireConfigurationWrite()
            try consumeWrites(1)
            session.stopLearning()
            return .object(["learningControl": .null])
        case "restrict_configuration_write":
            try requireConfigurationWrite()
            guard session.engine.learnTarget == nil else { throw MCPToolFailure(L10n.text("请先停止控件学习")) }
            try consumeWrites(1)
            try onRestrictConfigurationWrite?()
            permissions.configurationWrite = false
            return try .encoded(permissions)
        case "assign_control":
            try requireConfigurationWrite()
            let assignment = try args["assignment"]!.decoded(ControlAssignment.self)
            if case let .agentPrimaryAction(slot) = assignment.target, !(1 ... 8).contains(slot.rawValue) {
                throw MCPToolFailure(L10n.text("Agent 槽位必须为 1–8"))
            }
            if case let .resetGroup(group) = assignment.target,
               !session.engine.configuration.parameterGroups
                   .contains(group) { throw MCPToolFailure(L10n.text("未知参数组")) }
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
                throw MCPToolFailure(L10n.text("MCP 不允许修改使能参数定义：\(definition.id)"))
            }
            if name == "update_parameter", let previous = session.engine.configuration.parameter(definition.id) {
                guard previous.agentWritable
                else { throw MCPToolFailure(L10n.text("MCP 不允许修改不可写参数定义：\(definition.id)")) }
                guard previous.agentWritable == definition.agentWritable,
                      previous.externallyProtected == definition.externallyProtected
                else {
                    throw MCPToolFailure(L10n.text("MCP 不允许修改 agentWritable"))
                }
            }
            guard definition.defaultValue.isFinite,
                  (definition.minimum ... definition.maximum).contains(definition.defaultValue)
            else {
                throw MCPToolFailure(L10n.text("默认值必须在参数范围内"))
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
        default: throw MCPToolFailure(L10n.text("未知工具"))
        }
    }

    func write(_ entries: [(ParameterID, Double)]) throws -> [JSONValue] {
        guard permissions.parameterWrite else { throw MCPToolFailure(L10n.text("未开启参数写入权限")) }
        var seen = Set<ParameterID>()
        for (id, value) in entries {
            guard value.isFinite else { throw MCPToolFailure(L10n.text("参数值必须是有限数值")) }
            guard seen.insert(id).inserted else { throw MCPToolFailure(L10n.text("批量写入包含重复参数：\(id)")) }
            guard let definition = session.engine.configuration.parameter(id)
            else { throw MCPToolFailure(L10n.text("未知参数：\(id)")) }
            guard definition.agentWritable,
                  !session.isMCPProtectedParameter(id) else { throw MCPToolFailure(L10n.text("参数不允许 Agent 写入：\(id)")) }
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

    func parameterInfo(_ id: ParameterID) throws -> JSONValue {
        guard let definition = session.engine.configuration.parameter(id),
              let value = session.engine.value(of: id),
              case var .object(info) = try JSONValue.encoded(definition)
        else {
            throw MCPToolFailure(L10n.text("未知参数：\(id)"))
        }
        info["value"] = .double(value)
        info["actualValue"] = session.engine.actualFeedbackValues[id].map(JSONValue.double) ?? .null
        info["outputValue"] = session.motionSafety?.outputs[id].map(JSONValue.double) ?? .null
        info["writable"] = .bool(permissions.parameterWrite && definition.agentWritable && !session
            .isMCPProtectedParameter(id))
        info["controls"] = .array(try session.engine.configuration.controls(targetingParameter: id)
            .map(JSONValue.encoded))
        return .object(info)
    }

    func motionSafetyInfo() -> JSONValue {
        guard let safety = session.motionSafety else { return .null }
        func values(_ input: [ParameterID: Double]) -> JSONValue {
            .object(Dictionary(uniqueKeysWithValues: input.map { ($0.key.rawValue, .double($0.value)) }))
        }
        return .object(["status": .string(safety.status.rawValue), "reason": .string(safety.reason),
                        "limited": .bool(safety.limited), "outputs": values(safety.outputs),
                        "actual": values(safety.actual),
                        "baseline": values(safety.baseline)])
    }

    func requireSavedConfiguration() throws {
        if let error = session.lastConfigurationPersistenceError {
            throw MCPToolFailure(L10n.text("配置已在内存更新，但持久化失败：\(error)"))
        }
    }

    func requireConfigurationWrite() throws {
        guard permissions.parameterWrite,
              permissions.configurationWrite else { throw MCPToolFailure(L10n.text("未开启配置写入权限")) }
    }

    func endpointSelectionInfo(_ selection: MIDIEndpointSelection) -> JSONValue {
        .object(["sourceID": selection.sourceID.map { .number(Int($0)) } ?? .null,
                 "destinationID": selection.destinationID.map { .number(Int($0)) } ?? .null])
    }

    func requireInactiveOutput() throws {
        guard session.motionSafety == nil || session.motionSafety?.status == .disconnected else {
            throw MCPToolFailure(L10n.text("请先停止外部输出"))
        }
    }

    func requireHardwareConnection() throws {
        guard session.connection.isConnected, session.connection.lastError == nil else {
            throw MCPToolFailure(L10n.text("实体 MIDI 双向连接不可用"))
        }
    }
}
