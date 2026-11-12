import BCRCoreMIDIDriver
import BCRSurfaceDomain

/// Minimal recording transport; snapshot/preset/failure-specific devices keep their own behavior.
@MainActor
public final class RecordingMIDIService: MIDIService {
    public var connection: MIDIConnectionSnapshot
    public var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    public var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    public var sent: [MIDIVoiceMessage] = []
    private let notifyOnStart: Bool

    public init(
        connection: MIDIConnectionSnapshot = .init(connectedSource: "Test input", connectedDestination: "Test output"),
        notifyOnStart: Bool = false
    ) {
        self.connection = connection
        self.notifyOnStart = notifyOnStart
    }

    public func start() throws { if notifyOnStart { onConnection?(connection) } }
    public func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    public func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
}
