import BCRFoundation
import Foundation

/// Optional Agent capability adapter. Runtime ownership is supplied by the host.
public enum AgentMCPModule {
    public static let names = ["get_agents", "start_agent", "interrupt_agent", "stop_all_agents"]
}

extension AgentControlService {
    func executeAgent(_ name: String, _ args: [String: JSONValue]) throws -> JSONValue {
        switch name {
        case "get_agents":
            guard let onReadAgents else { throw MCPToolFailure(L10n.text("Agent 服务不可用")) }
            return try onReadAgents()
        case "start_agent", "interrupt_agent", "stop_all_agents":
            guard permissions.parameterWrite,
                  permissions.agentControl else { throw MCPToolFailure(L10n.text("未开启 Agent 控制权限")) }
            guard let onAgentAction else { throw MCPToolFailure(L10n.text("Agent 服务不可用")) }
            let slot = name == "stop_all_agents" ? nil : try agentSlot(args)
            try consumeWrites(1)
            try onAgentAction(name, slot)
            return .object(["accepted": .bool(true)])
        default: throw MCPToolFailure(L10n.text("未知工具"))
        }
    }

    func agentSlot(_ args: [String: JSONValue]) throws -> AgentSlotID {
        guard let value = args["slot"]?.finiteNumber, value.rounded() == value, (1 ... 8).contains(value) else {
            throw MCPToolFailure(L10n.text("Agent 槽位必须为 1–8"))
        }
        return AgentSlotID(Int(value))
    }
}
