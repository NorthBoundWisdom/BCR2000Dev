import BCRFoundation
import Foundation

@MainActor
private final class ReplayClock { var now = 0.0 }

/// This device has no system handles and cannot connect. Even accidental hardware selection fails closed.
@MainActor
private final class ReplayUnconnectedDevice: SurfaceDevice {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    func send(_ message: MIDIVoiceMessage) throws { throw CaptureDocumentError.invalidRecord }
}

/// Owns a new session, Mock and injected record clock. No live host, plugin runtime, MCP or output port exists here.
@MainActor
public final class RecordedCaptureReplay {
    public let capture: RecordedCapture
    public private(set) var session: SurfaceSession
    public private(set) var cursor = 0
    public private(set) var inputsReplayed = 0
    public private(set) var recordedOutputsSkipped = 0
    public private(set) var ignoredEvents = 0
    private var mockDevice: MockSurfaceDevice
    private let clock: ReplayClock
    public var isAtEnd: Bool { cursor >= capture.events.count }
    public var mock: MockBCR2000 { session.mock }

    public init(capture: RecordedCapture) throws {
        guard let header = capture.header, header["schemaVersion"]?.exactIntValue == 1,
              let context = header["session"]?.objectValue,
              let timestamp = header["monotonicTimestamp"]?.finiteNumber,
              timestamp >= 0 else { throw CaptureDocumentError.missingContext }
        self.capture = capture
        let clock = ReplayClock(); self.clock = clock
        clock.now = timestamp
        (session, mockDevice) = try Self.makeSession(context, clock: clock)
    }

    private static func makeSession(_ context: [String: JSONValue],
                                    clock: ReplayClock) throws -> (SurfaceSession, MockSurfaceDevice)
    {
        let context = try RecordedCaptureContext(fields: context)
        let configuration = context.configuration, map = context.hardwareMap
        let mock = MockSurfaceDevice(model: MockBCR2000(preset: map))
        let session = SurfaceSession(hardwareDevice: ReplayUnconnectedDevice(), mockDevice: mock,
                                     configuration: configuration,
                                     now: { Date(timeIntervalSinceReferenceDate: clock.now) },
                                     historyTime: .init(now: { clock.now }),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        for id in context.parameterValues.keys.sorted() { session.setParameter(id, to: context.parameterValues[id]!) }
        if let page = context.activePageID { try session.selectPage(page) }
        return (session, mock)
    }

    @discardableResult
    public func step() throws -> Bool {
        guard !isAtEnd else { return false }
        let event = capture.events[cursor]
        defer { cursor += 1 }
        guard let time = event.monotonicTime, time >= clock.now else { ignoredEvents += 1; return true }
        clock.now = time
        if event.isContext, let context = event.fields["session"]?.objectValue {
            (session, mockDevice) = try Self.makeSession(context, clock: clock)
        } else if event.direction == "OUT" {
            recordedOutputsSkipped += 1 // Do not deliver recorded output even to the isolated Mock.
        } else if event.direction == "IN", !event.ignored, !event.messages.isEmpty {
            try mockDevice.applyCapturedInput(event.messages)
            inputsReplayed += 1
        } else { ignoredEvents += 1 }
        return true
    }

    public func reset() throws {
        guard let header = capture.header, let context = header["session"]?.objectValue,
              let timestamp = header["monotonicTimestamp"]?.finiteNumber, timestamp >= 0
        else {
            throw CaptureDocumentError.missingContext
        }
        clock.now = timestamp
        (session, mockDevice) = try Self.makeSession(context, clock: clock)
        cursor = 0; inputsReplayed = 0; recordedOutputsSkipped = 0; ignoredEvents = 0
    }
}
