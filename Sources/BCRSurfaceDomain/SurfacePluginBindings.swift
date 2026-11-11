import SurfacePluginContracts

/// Host-supplied interpretation of persisted targets. Device/domain code never invents
/// plugin namespaces. Unmapped legacy targets retain their source-compatible behavior.
public struct SurfacePluginBindings: Equatable, Sendable {
    public var actions: [ControlTarget: ActionReference]
    public var indicators: [ControlTarget: IndicatorID]

    public init(actions: [ControlTarget: ActionReference] = [:], indicators: [ControlTarget: IndicatorID] = [:]) {
        self.actions = actions
        self.indicators = indicators
    }
}
