import BCRFoundation
import Foundation

public enum DeviceSource: String, CaseIterable, Identifiable, Sendable {
    case mock
    case hardware

    public var id: String { rawValue }
}

/// Value-only connection information; CoreMIDI endpoint lifetimes stay in the app.
public struct MIDIConnectionSnapshot: Equatable, Sendable {
    public var sourceEndpoints: [MIDIEndpointDescriptor] = []
    public var destinationEndpoints: [MIDIEndpointDescriptor] = []
    public var connectedSourceID: Int32?
    public var connectedDestinationID: Int32?
    public var sourceNames: [String] = []
    public var destinationNames: [String] = []
    public var connectedSource: String?
    public var connectedDestination: String?
    public var lastError: String?

    public init(
        sourceNames: [String] = [], destinationNames: [String] = [],
        connectedSource: String? = nil, connectedDestination: String? = nil,
        lastError: String? = nil
    ) {
        self.sourceNames = sourceNames
        self.destinationNames = destinationNames
        self.connectedSource = connectedSource
        self.connectedDestination = connectedDestination
        self.lastError = lastError
    }

    public var isConnected: Bool {
        connectedSource != nil && connectedDestination != nil
    }
}

/// One session owns these callbacks. Adapters hand decoded values to the main actor.
@MainActor
public protocol SurfaceDevice: AnyObject {
    var connection: MIDIConnectionSnapshot { get }
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)? { get set }
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)? { get set }
    func send(_ message: MIDIVoiceMessage) throws
}

/// Adapts the deterministic value model without adding real-device preset assumptions.
@MainActor
public final class MockSurfaceDevice: SurfaceDevice {
    public private(set) var model: MockBCR2000
    public let connection = MIDIConnectionSnapshot(
        connectedSource: "Mock BCR2000",
        connectedDestination: "Mock BCR2000"
    )
    public var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    public var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?

    public init(model: MockBCR2000 = MockBCR2000()) {
        self.model = model
    }

    public func send(_ message: MIDIVoiceMessage) throws {
        try message.validate()
        model.receive(message)
    }

    public func configureModes(_ configuration: SurfaceConfiguration) {
        model.encoderModes = Dictionary(uniqueKeysWithValues: configuration.assignments.map { (
            $0.control,
            $0.encoderMode
        ) })
    }

    public func setNRPN(_ enabled: Bool, for control: BCRControlID) throws {
        try model.setNRPN(enabled, for: control)
    }

    public func selectGroup(_ group: Int) {
        model.activeGroup = group
    }

    public func turn(_ control: BCRControlID, by delta: Int) {
        if let message = model.turn(control, by: delta) {
            if case .nrpn = message {
                // Emit the same four CCs as the wire, as one decoded callback batch.
                let bytes = message.midi1Bytes
                let parts: [MIDIVoiceMessage] = stride(from: 0, to: bytes.count, by: 3).map {
                    .controlChange(channel: bytes[$0] & 15, number: bytes[$0 + 1], value: bytes[$0 + 2])
                }
                onMessages?(parts)
            } else { onMessages?([message]) }
        }
    }

    public func press(_ control: BCRControlID) {
        if let message = model.press(control) { onMessages?([message]) }
    }

    public func release(_ control: BCRControlID) {
        if let message = model.release(control) { onMessages?([message]) }
    }
}
