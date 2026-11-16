import BCRFoundation
import Foundation

public enum CaptureDocumentError: LocalizedMessageError, Equatable, Sendable {
    case tooLarge, tooManyEvents, missingContext, invalidRecord, foreignDevice(String)
    public var localizedMessage: LocalizedMessage {
        switch self {
        case .tooLarge: "录制文件超过 16 MiB 上限"
        case .tooManyEvents: "录制事件超过 200000 条上限"
        case .missingContext: "录制缺少可验证的 BCR 会话快照，无法重播"
        case .invalidRecord: "录制事件无效，已停止重播"
        case let .foreignDevice(model): "录制来自其他设备（\(model)），不能在 BCR2000 中重播"
        }
    }
}

public struct CaptureIntegrityReview: Equatable, Sendable {
    public var unsupportedVersions = 0
    public var nonMonotonicTimestamps = 0
    public var invalidTimestamps = 0
    public var truncatedLines = 0
    public var unparseableLines = 0
    public var sequenceErrors = 0
    public var boundaryErrors = 0
    public var contextErrors = 0
    public var isComplete: Bool {
        unsupportedVersions + nonMonotonicTimestamps + invalidTimestamps + truncatedLines +
            unparseableLines + sequenceErrors + boundaryErrors + contextErrors == 0
    }
}

public struct RecordedCaptureEvent: Equatable, Sendable {
    public let fields: [String: JSONValue]
    public let sequence: Int
    public let monotonicTime: Double?
    public let messages: [MIDIVoiceMessage]
    public var direction: String? { fields["direction"]?.stringValue }
    public var isContext: Bool { fields["origin"] == .string("contextChanged") }
    public var ignored: Bool { fields["ignored"] == .bool(true) }

    init(fields: [String: JSONValue]) throws {
        guard let sequence = fields["sequence"]?.exactIntValue,
              sequence > 0 else { throw CaptureDocumentError.invalidRecord }
        self.fields = fields; self.sequence = sequence
        monotonicTime = fields["monotonicTimestamp"]?.finiteNumber
        if let direction = fields["direction"], direction != .null, direction != .string("IN"),
           direction != .string("OUT")
        {
            throw CaptureDocumentError.invalidRecord
        }
        if let ignored = fields["ignored"], ignored != .bool(true), ignored != .bool(false) {
            throw CaptureDocumentError.invalidRecord
        }
        guard let raw = fields["rawMIDI1Bytes"], raw != .null else {
            if fields["direction"] == nil || fields["direction"] == .null { messages = []; return }
            if fields["connection"]?.objectValue != nil || fields["nonMotorTest"]?.objectValue != nil {
                messages = []; return
            }
            if fields["origin"] == .string("contextChanged"), fields["session"]?.objectValue != nil {
                messages = []; return
            }
            guard let summary = fields["sysEx"]?.objectValue, summary["redacted"] == .bool(true),
                  let count = summary["byteCount"]?.exactIntValue, count > 0,
                  let hash = summary["sha256"]?.stringValue, hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) })
            else { throw CaptureDocumentError.invalidRecord }
            messages = []; return
        }
        guard fields["direction"]?.stringValue != nil,
              let source = fields["source"]?.stringValue, ["hardware", "mock", "agent", "application"].contains(source)
        else { throw CaptureDocumentError.invalidRecord }
        guard let array = raw.arrayValue, !array.isEmpty, array.count <= 12 else {
            throw CaptureDocumentError.invalidRecord
        }
        let bytes = try array.map { value -> UInt8 in
            guard let integer = value.exactIntValue,
                  let byte = UInt8(exactly: integer) else { throw CaptureDocumentError.invalidRecord }
            return byte
        }
        var messages: [MIDIVoiceMessage] = []
        var index = 0
        while index < bytes.count {
            let status = bytes[index] & 0xF0
            guard (0x80 ... 0xE0).contains(status) else { throw CaptureDocumentError.invalidRecord }
            let size = status == 0xC0 || status == 0xD0 ? 2 : 3
            guard index + size <= bytes.count, bytes[(index + 1) ..< (index + size)].allSatisfy({ $0 < 128 })
            else { throw CaptureDocumentError.invalidRecord }
            let channel = bytes[index] & 15, number = bytes[index + 1]
            let value = size == 3 ? bytes[index + 2] : 0
            switch status {
            case 0x80: messages.append(.noteOff(channel: channel, number: number, velocity: value))
            case 0x90: messages.append(.noteOn(channel: channel, number: number, velocity: value))
            case 0xB0: messages.append(.controlChange(channel: channel, number: number, value: value))
            default: break // Preserve valid common bytes; BCR does not interpret other devices' messages.
            }
            index += size
        }
        self.messages = messages
    }
}

/// Recoverable line errors stay visible with separate counts. Replay only consumes validated rows.
public struct RecordedCapture: Equatable, Sendable {
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumEvents = 200_000
    public let header: [String: JSONValue]?
    public let events: [RecordedCaptureEvent]
    public let review: CaptureIntegrityReview
    public let sha256: String
    public let byteCount: Int
    public var deviceModel: String? { header?["session"]?.objectValue?["deviceModel"]?.stringValue }
    public var isForeignDevice: Bool { deviceModel.map { $0 != "BCR2000" } ?? false }

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw CaptureDocumentError.tooLarge }
        var review = CaptureIntegrityReview(), header: [String: JSONValue]?
        var events: [RecordedCaptureEvent] = []
        var lastTime: Double?, ended = false, sawEnd = false, eventRows = 0, expectedSequence = 1
        let audit = ISO8601DateFormatter()
        audit.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainAudit = ISO8601DateFormatter()
        plainAudit.formatOptions = [.withInternetDateTime]
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        let completeLines = lines.dropLast() // An unterminated final line is evidence, never an executable event.
        if data.last != 10 { review.truncatedLines = 1 }
        for line in completeLines {
            guard !line.isEmpty,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  let fields = value.objectValue, let kind = fields["kind"]?.stringValue
            else { review.unparseableLines += 1; continue }
            if ended { review.boundaryErrors += 1 }
            let model = (kind == "capture-start" ? fields : header)?["session"]?.objectValue?["deviceModel"]?
                .stringValue
            let foreign = model.map { $0 != "BCR2000" } ?? false
            if foreign {
                // Audit Date may jump. Validate its syntax when present, never invent a
                // monotonic clock or compare another process's clock with BCR replay time.
                if let stamp = fields["timestamp"], stamp != .null {
                    guard let value = stamp.stringValue,
                          audit.date(from: value) != nil || plainAudit.date(from: value) != nil
                    else { review.invalidTimestamps += 1; continue }
                }
            } else if let time = fields["monotonicTimestamp"]?.finiteNumber, time >= 0 {
                if let previous = lastTime, time < previous { review.nonMonotonicTimestamps += 1 }
                lastTime = time
            } else { review.invalidTimestamps += 1 }
            switch kind {
            case "capture-start":
                if header != nil || eventRows > 0 { review.boundaryErrors += 1 }
                if fields["schemaVersion"]?.exactIntValue != 1 { review.unsupportedVersions += 1 }
                if let version = fields["hostFormatVersion"],
                   version.exactIntValue != 1 { review.unsupportedVersions += 1 }
                if !foreign {
                    do { _ = try RecordedCaptureContext(fields: fields["session"]?.objectValue ?? [:]) }
                    catch { review.contextErrors += 1 }
                }
                if header == nil { header = fields }
            case "event":
                eventRows += 1
                guard eventRows <= Self.maximumEvents else { throw CaptureDocumentError.tooManyEvents }
                if header == nil { review.boundaryErrors += 1 }
                if fields["sequence"]?.exactIntValue != expectedSequence { review.sequenceErrors += 1 }
                expectedSequence += 1
                do {
                    let event = try RecordedCaptureEvent(fields: fields)
                    if event.isContext, !foreign {
                        do { _ = try RecordedCaptureContext(fields: fields["session"]?.objectValue ?? [:]) }
                        catch { review.contextErrors += 1 }
                    }
                    events.append(event)
                } catch { review.unparseableLines += 1 }
            case "capture-end":
                if header == nil || sawEnd { review.boundaryErrors += 1 }
                if fields["eventCount"]?.exactIntValue != eventRows { review.sequenceErrors += 1 }
                sawEnd = true; ended = true
            default: review.unparseableLines += 1
            }
        }
        if header == nil { review.boundaryErrors += 1 }
        if !sawEnd { review.boundaryErrors += 1 }
        self.header = header; self.events = events; self.review = review
        sha256 = ContentDigest.sha256(data); byteCount = data.count
    }
}

/// Validates the recorded values and mapping without constructing any runtime or touching a device.
public struct RecordedCaptureContext: Sendable {
    public let configuration: SurfaceConfiguration
    public let hardwareMap: HardwareMap
    public let parameterValues: [ParameterID: Double]
    public let activePageID: String?
    public init(fields: [String: JSONValue]) throws {
        guard fields["deviceModel"] == .string("BCR2000"),
              let rawConfiguration = fields["configuration"], let rawMap = fields["hardwareMap"],
              let values = fields["parameterValues"]?.objectValue
        else { throw CaptureDocumentError.missingContext }
        configuration = try rawConfiguration.decoded(SurfaceConfiguration.self)
        hardwareMap = try rawMap.decoded(HardwareMap.self)
        try configuration.validate(); try hardwareMap.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard fields["mappingFingerprint"] == .string(ContentDigest.sha256(try encoder.encode(hardwareMap))),
              Set(values.keys) == Set(configuration.parameters.map { $0.id.rawValue })
        else { throw CaptureDocumentError.missingContext }
        var checked: [ParameterID: Double] = [:]
        for definition in configuration.parameters {
            guard let value = values[definition.id.rawValue]?.finiteNumber,
                  definition.clamp(value) == value else { throw CaptureDocumentError.missingContext }
            checked[definition.id] = value
        }
        parameterValues = checked
        if let page = fields["activePageID"], page != .null {
            guard let id = page.stringValue, configuration.pages.contains(where: { $0.id == id })
            else { throw CaptureDocumentError.missingContext }
            activePageID = id
        } else { activePageID = nil }
    }
}
