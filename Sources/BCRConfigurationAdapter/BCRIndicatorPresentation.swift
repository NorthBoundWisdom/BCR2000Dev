import BCRAgentDomain
import SurfacePluginContracts

/// The BCR device's seven-bit presentation is independent of the shared plugin contract.
public enum BCRIndicatorPresentation {
    public static func value(for semantic: IndicatorSemantic) -> UInt8 {
        switch semantic {
        case .idle: 0
        case .queued: 40
        case .active: 127
        case .attention: 96
        case .done: 72
        case .stopped: 20
        case .fault: 8
        }
    }
}

/// Old BCRAgentCore presentation API; no MIDI value exists in the shared state enum.
public extension AgentRunState {
    var feedbackValue: UInt8 { BCRIndicatorPresentation.value(for: indicatorSemantic) }
}
