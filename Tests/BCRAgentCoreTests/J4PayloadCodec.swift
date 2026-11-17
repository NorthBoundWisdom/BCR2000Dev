import Foundation
import SurfaceDeviceConformance

/// The sole Tests hot-path raw parser. Strict raw admission and AST construction are one pass.
enum J4PayloadCodec {
    static func payload(_ data: Data) throws -> ScenarioPayload {
        try SchedulerTraceCodec.decodePayload(data)
    }

    static func envelope(_ data: Data) throws -> SchedulerEnvelope {
        try envelope(payload: payload(data))
    }

    static func envelope(payload: ScenarioPayload) throws -> SchedulerEnvelope {
        try SchedulerTraceCodec.decodeInput(payload: payload)
    }

    /// Preserve the original native Any→JSON boundary; no NSNumber visitor or repair/fallback.
    static func any(_ value: Any) throws -> ScenarioPayload {
        try payload(JSONSerialization.data(withJSONObject: value))
    }
}
