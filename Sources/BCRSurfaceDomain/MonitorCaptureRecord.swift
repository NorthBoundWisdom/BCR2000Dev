import BCRFoundation
import Foundation

/// Common JSONL keys follow X-Touch v1; BCR-only observations are additive fields.
public struct MonitorCaptureRecord: Equatable, Sendable {
    public var fields: [String: JSONValue]
    public init(fields: [String: JSONValue]) { self.fields = fields }
    public var kind: String? { fields["kind"]?.stringValue }

    public static func start(sessionID: String, applicationVersion: String, source: DeviceSource,
                             connection: MIDIConnectionSnapshot, mappingFingerprint: String,
                             configuration: SurfaceConfiguration, hardwareMap: HardwareMap,
                             parameterValues: [ParameterID: Double],
                             at date: Date, monotonic: Double) throws -> Self
    {
        func endpoint(_ id: Int32?, _ name: String?) -> JSONValue {
            guard let id, let name else { return .null }
            return .object(["id": .number(Int(id)), "name": .string(name)])
        }
        return Self(fields: [
            "kind": .string("capture-start"), "schemaVersion": .number(1), "hostFormatVersion": .number(1),
            "timestamp": .string(timestamp(date)), "monotonicTimestamp": .double(monotonic),
            "byteFormat": .string("canonical MIDI 1; SysEx payloads redacted"),
            "session": .object([
                "sessionID": .string(sessionID), "applicationVersion": .string(applicationVersion),
                "sourceRevision": .null, "sourceTreeDirty": .null,
                "bcrPortNames": .object(["input": connection.connectedSource.map(JSONValue.string) ?? .null,
                                         "output": connection.connectedDestination.map(JSONValue.string) ?? .null]),
                "bcrDisplay": .object(["digits": .number(4), "text": .null,
                                       "observation": .string("device does not report display text over MIDI")]),
                "deviceModel": .string("BCR2000"), "deviceSource": .string(source.rawValue),
                "hardwareMode": .bool(source == .hardware),
                "connectedInput": endpoint(connection.connectedSourceID, connection.connectedSource),
                "connectedOutput": endpoint(connection.connectedDestinationID, connection.connectedDestination),
                "mappingFingerprint": .string(mappingFingerprint), "mappingFingerprintAlgorithm": .string("sha256"),
                "clockDomain": .string("host monotonic seconds; timestamps are audit-only"),
                "configuration": try .encoded(configuration), "hardwareMap": try .encoded(hardwareMap),
                "activePageID": configuration.activePageID.map(JSONValue.string) ?? .null,
                "parameterValues": .object(Dictionary(uniqueKeysWithValues: parameterValues.map {
                    ($0.key.rawValue, .double($0.value))
                }))
            ])
        ])
    }

    public static func event(_ event: MonitorEvent, feedbackEcho: Bool = false, hardwareMode: Bool? = nil) -> Self {
        let origin = event.origin == .agent ? "agent" : (event.origin == .external ? "externalState" :
            (event.direction == .input ? "deviceInput" : "softwareFeedback"))
        var fields: [String: JSONValue] = [
            "kind": .string("event"), "timestamp": .string(timestamp(event.time)),
            "monotonicTimestamp": .double(event.monotonicTime),
            "source": .string(event.direction == .input ? event.source.rawValue :
                (event.origin == .agent ? "agent" : (event.source == .mock ? "mock" : "application"))),
            "hardwareMode": .bool(hardwareMode ?? (event.source == .hardware)),
            "deviceSource": .string(event.source.rawValue), "origin": .string(origin),
            "direction": .string(event.direction == .input ? "IN" : "OUT"),
            "ignored": .bool(event.ignored || feedbackEcho), "echo": .bool(feedbackEcho),
            "rawMIDI1Bytes": .array(event.message.midi1Bytes.map { .number(Int($0)) }),
            "message": .string(event.message.diagnosticDescription),
            "control": event.control.map { .string($0.shortName) } ?? .null,
            "bcrControl": event.control.map { .object(["section": .string($0.section.rawValue),
                                                       "row": .number($0.row), "index": .number($0.index)]) } ?? .null,
            "decoded": .object(["value": .number(Int(event.message.dataValue)),
                                "kind": .string(event.message.controlID.kind.rawValue),
                                "channel": .number(Int(event.message.controlID.channel) + 1),
                                "number": .number(Int(event.message.controlID.number))])
        ]
        fields["delivery"] = event.direction == .input ? .string("received") : event.delivery
            .map { .string($0.rawValue) }
        return Self(fields: fields)
    }

    /// Preset/BCL content never enters the record, including names and personal preset bytes.
    public static func sysEx(_ data: Data, at date: Date, monotonic: Double, source: DeviceSource = .hardware) -> Self {
        Self(fields: ["kind": .string("event"), "timestamp": .string(timestamp(date)),
                      "monotonicTimestamp": .double(monotonic), "source": .string(source.rawValue),
                      "hardwareMode": .bool(source == .hardware), "ignored": .bool(false),
                      "delivery": .string("received"),
                      "direction": .string("IN"), "origin": .string("deviceInput"),
                      "sysEx": .object(["byteCount": .number(data.count),
                                        "sha256": .string(ContentDigest.sha256(data)), "redacted": .bool(true)])])
    }

    public static func end(at date: Date, monotonic: Double, eventCount: Int) -> Self {
        Self(fields: ["kind": .string("capture-end"), "timestamp": .string(timestamp(date)),
                      "monotonicTimestamp": .double(monotonic), "eventCount": .number(eventCount)])
    }

    /// One common row carries one canonical MIDI 1 message, never an NRPN concatenation.
    /// The logical NRPN remains explicit in an additive BCR field on each of its four CC rows.
    public var canonicalMIDI1Records: [Self] {
        guard fields["decoded"]?.objectValue?["kind"] == .string("nrpn"),
              let raw = fields["rawMIDI1Bytes"]?.arrayValue, raw.count == 12 else { return [self] }
        let bytes = raw.compactMap(\.exactIntValue)
        guard bytes.count == 12, bytes.allSatisfy({ (0 ... 255).contains($0) }) else { return [self] }
        return stride(from: 0, to: raw.count, by: 3).map { index in
            var part = self
            part.fields["bcrNRPN"] = fields["decoded"]
            part.fields["rawMIDI1Bytes"] = .array(Array(raw[index ..< index + 3]))
            let channel = (bytes[index] & 15) + 1
            let number = bytes[index + 1], value = bytes[index + 2]
            part.fields["decoded"] = .object(["kind": .string("controlChange"), "channel": .number(channel),
                                              "number": .number(number), "value": .number(value)])
            part.fields["message"] = .string("CC ch\(channel) #\(number)=\(value)")
            return part
        }
    }

    public func encodedLine() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(fields)) + Data([10])
    }

    public static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }
}

/// Optional passive SysEx receive tap. It never acquires a port or requests a transfer.
@MainActor
public protocol SurfaceSysExObserving: SurfaceDevice {
    var onSysExObservation: (@MainActor (Data) -> Void)? { get set }
}
