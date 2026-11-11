import BCRFoundation
import BCRSurfaceDomain
import Foundation
import SurfacePluginContracts

/// The only interpretation of the old Agent binding representation. Keep disk/Provider
/// JSON unchanged while production engines receive ordinary action and indicator IDs.
public enum AgentBindingTranslation {
    public static func action(for slot: AgentSlotID) throws -> ActionReference {
        _ = try AgentSlotID(validating: slot.rawValue)
        return .init(pluginID: "agent", actionID: "agent.primary", index: slot.rawValue)
    }

    public static func slot(for action: ActionReference) throws -> AgentSlotID {
        guard action.pluginID == "agent", action.actionID == "agent.primary", let index = action.index else {
            throw PluginError(code: .unknownAction)
        }
        return try AgentSlotID(validating: index)
    }

    public static func indicator(for slot: AgentSlotID) -> IndicatorID {
        .init(rawValue: "agent.slot.\(slot.rawValue)")
    }

    public static var bindings: SurfacePluginBindings {
        let slots = (1 ... 8).map { AgentSlotID($0) }
        return .init(actions: Dictionary(uniqueKeysWithValues: slots.map {
            (.agentPrimaryAction($0), .init(pluginID: "agent", actionID: "agent.primary", index: $0.rawValue))
        }), indicators: Dictionary(uniqueKeysWithValues: slots.map {
            (.agentPrimaryAction($0), indicator(for: $0))
        }))
    }
}

/// Legacy source facade. The domain stores only neutral indicator IDs, never slot state.
public extension SurfaceEngine {
    var agentFeedback: [AgentSlotID: UInt8] {
        Dictionary(uniqueKeysWithValues: (1 ... 8).compactMap { index in
            let slot = AgentSlotID(index)
            return indicatorFeedback[AgentBindingTranslation.indicator(for: slot)].map { (slot, $0) }
        })
    }

    mutating func setAgentFeedback(_ slot: AgentSlotID, value: UInt8, at now: Date = .now) -> [SurfaceEffect] {
        let indicator = AgentBindingTranslation.indicator(for: slot)
        bindIndicator(indicator, to: .agentPrimaryAction(slot))
        return setIndicatorFeedback(indicator, value: value, at: now)
    }
}

public extension SurfaceSession {
    func setAgentFeedback(_ slot: AgentSlotID, value: UInt8) {
        let indicator = AgentBindingTranslation.indicator(for: slot)
        bindIndicator(indicator, to: .agentPrimaryAction(slot))
        setIndicatorFeedback(indicator, value: value)
    }
}
