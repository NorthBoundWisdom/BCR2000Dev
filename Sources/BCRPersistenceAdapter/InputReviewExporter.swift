import BCRFoundation
import BCRSurfaceDomain
import Foundation

public struct InputReviewExportReceipt: Equatable, Sendable {
    public let path: String
    public let sha256: String
}

/// JSON keys mirror the sibling host's evidence vocabulary; BCR groups replace A/B layers.
public enum InputReviewExporter {
    public static func export(to url: URL, coverage: InputCoverage, map: HardwareMap,
                              applicationVersion: String, source: DeviceSource,
                              connection: MIDIConnectionSnapshot, observationStarted: Date,
                              generatedAt: Date, contextID: String) throws -> InputReviewExportReceipt
    {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let fingerprint = ContentDigest.sha256(try encoder.encode(map))
        func endpoint(_ id: Int32?, _ name: String?) -> JSONValue {
            guard let name else { return .null }
            return .object(["id": id.map { .number(Int($0)) } ?? .null, "name": .string(name)])
        }
        let groups: [JSONValue] = BCRSection.allCases.flatMap { section in
            section.rowRange.map { row in
                .object(["group": .string(section.rawValue + "." + String(row)),
                         "section": .string(section.rawValue), "row": .number(row),
                         "controls": .array(BCRLayout.allControls.filter { $0.section == section && $0.row == row }
                             .map { control in
                                 let review = coverage.review(control)
                                 return .object([
                                     "control": .string(control.shortName), "bcrControl": .object([
                                         "section": .string(control.section.rawValue), "row": .number(control.row),
                                         "index": .number(control.index)
                                     ]),
                                     "eventCount": .number(review.eventCount),
                                     "minimum": review.minimum.map { .number(Int($0)) } ?? .null,
                                     "maximum": review.maximum.map { .number(Int($0)) } ?? .null,
                                     "latestValue": review.latestValue.map { .number(Int($0)) } ?? .null,
                                     "matchesMapping": review.matches(map.midi(for: control))
                                         .map(JSONValue.bool) ?? .null,
                                     "addresses": .array(review.addresses.map(\.description).sorted()
                                         .map(JSONValue.string)),
                                     "lastReceived": review.lastReceived
                                         .map { .string(MonitorCaptureRecord.timestamp($0)) } ?? .null,
                                     "lastMonotonicTimestamp": review.lastMonotonicTime.map(JSONValue.double) ?? .null
                                 ])
                             })])
            }
        }
        let report: JSONValue = .object([
            "kind": .string("bcr.input-review"), "schemaVersion": .number(1),
            "generatedAt": .string(MonitorCaptureRecord.timestamp(generatedAt)),
            "currentContext": .object([
                "contextID": .string(contextID), "applicationVersion": .string(applicationVersion),
                "deviceModel": .string("BCR2000"), "deviceSource": .string(source.rawValue),
                "connectedInput": endpoint(connection.connectedSourceID, connection.connectedSource),
                "connectedOutput": endpoint(connection.connectedDestinationID, connection.connectedDestination),
                "mappingFingerprint": .string(fingerprint), "mappingFingerprintAlgorithm": .string("sha256")
            ]),
            "hardwareAcceptance": .null,
            "observationStartedAt": .string(MonitorCaptureRecord.timestamp(observationStarted)),
            "observationMessageCount": .number(coverage.messageCount),
            "unmappedMessageCount": .number(coverage.unmappedMessageCount),
            "feedbackEchoCount": .number(coverage.echoCount),
            "observationScope": .string("passive session inputs; source explicit; not hardware sign-off"),
            "groups": .array(groups)
        ])
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report) + Data([10]), checksum = ContentDigest.sha256(data)
        let checksumURL = url.appendingPathExtension("sha256")
        guard !FileManager.default.fileExists(atPath: checksumURL.path) else { throw CocoaError(.fileWriteFileExists) }
        let file = try CaptureEvidenceFile(url: url)
        do { try file.write(data); try file.synchronize(); try file.close() }
        catch { try? file.close(); throw error }
        let hashFile = try CaptureEvidenceFile(url: checksumURL)
        do {
            try hashFile.write(Data("\(checksum)  \(url.lastPathComponent)\n".utf8)); try hashFile
                .synchronize(); try hashFile.close()
        } catch { try? hashFile.close(); throw error }
        return InputReviewExportReceipt(path: url.path, sha256: checksum)
    }
}
