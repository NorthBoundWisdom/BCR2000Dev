import BCRFoundation
import BCRCodexAdapter
import BCRSurfaceDomain
import BCRExamples
import BCRConfigurationAdapter
import BCRMCPAdapter
import BCRHTTPTransport
import BCRCoreMIDIDriver
import BCRPersistenceAdapter
import struct ParameterOutputPlugin.ParameterSample
import struct ParameterOutputPlugin.OSCMessage
import Foundation

/// Captured before MainActor delivery. Wall time is only the compatibility/audit projection.
struct OutputReceiptStamp: Sendable {
    let monotonic: Double
    let wall: Date
}

struct OutputReceivedBytes: Sendable {
    let data: Data
    let stamp: OutputReceiptStamp
}

struct OutputReceivedOSC: Sendable {
    let messages: [OSCMessage]
    let stamp: OutputReceiptStamp
}

struct OutputReceiveOverflow: Error, Sendable {}

/// Internal production capability; existing Date-based injected transports remain compatible.
@MainActor
protocol MonotonicOutputTransport: OutputTransport {
    var supportsMonotonicReceipts: Bool { get }
    var onPolicySamples: (@MainActor ([ParameterSample]) -> Void)? { get set }
    var onPolicyHeartbeat: (@MainActor (Double) -> Void)? { get set }
    var onPolicyPeerReset: (@MainActor (Double) -> Void)? { get set }
    func ping(atMonotonic time: Double) throws
}

extension MonotonicOutputTransport {
    var supportsMonotonicReceipts: Bool { true }
}
