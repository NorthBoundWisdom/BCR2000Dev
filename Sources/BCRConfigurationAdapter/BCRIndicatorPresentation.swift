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

/// How a two-state button LED shows a semantic: steady, or blinking between on and off.
/// The BCR2000's button LEDs have no brightness, so states differ by rhythm only.
public enum BCRIndicatorBlink: Equatable, Sendable {
    case steady(on: Bool)
    /// Period in seconds; the LED is on for the first half of each period.
    case blink(period: Double)

    public static func pattern(for semantic: IndicatorSemantic) -> BCRIndicatorBlink {
        switch semantic {
        case .idle, .stopped: .steady(on: false)
        case .active, .done: .steady(on: true)
        case .queued: .blink(period: 1.2)
        case .attention: .blink(period: 0.4)
        case .fault: .blink(period: 0.2)
        }
    }

    /// LED state at a monotonic time; phases are aligned so every blinking slot flashes together.
    public func isOn(at time: Double) -> Bool {
        switch self {
        case let .steady(on): return on
        case let .blink(period): return time.truncatingRemainder(dividingBy: period) < period / 2
        }
    }
}

/// Old BCRAgentCore presentation API; no MIDI value exists in the shared state enum.
public extension AgentRunState {
    var feedbackValue: UInt8 { BCRIndicatorPresentation.value(for: indicatorSemantic) }
}
