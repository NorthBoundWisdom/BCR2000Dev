import Foundation
import XCTest
import SurfaceDeviceConformance

/// Aggregate executable is part of the Tests graph only. Production records facts, never imports this support.
final class J4SchedulerArchiveReplayTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value
    }()

    private func object(_ value: ScenarioPayload) throws -> [String: ScenarioPayload] {
        guard case let .object(value) = value else { throw SchedulerCandidateError.invalid("object") }; return value
    }

    private func text(_ value: ScenarioPayload?) throws -> String {
        guard case let .scalar(.text(value)) = value
        else { throw SchedulerCandidateError.invalid("text") }; return value
    }

    private func nullable(_ value: Double?) -> ScenarioPayload { value.map { .scalar(.number($0)) } ?? .scalar(.null) }
    private func strings(_ values: [String]) -> ScenarioPayload { .array(values.map { .scalar(.text($0)) }) }
    private func write(_ value: ScenarioPayload, to file: FileHandle) throws {
        var data = try encoder.encode(value); data.append(10); try file.write(contentsOf: data)
    }

    func testReplayRecordedNativeSchedulerInputs() throws {
        guard let path = ProcessInfo.processInfo.environment["BCR_J4_REPLAY_ARCHIVE"] else {
            // A meaningful format gate during ordinary inventory execution. Full archive is replayed only
            // once after all primary native workers complete, never a partial concurrently written file.
            var candidate = SchedulerCandidate()
            let event = SchedulerEnvelope(owner: "format-negative", ordinal: 1, input: .initialize(.unlimited))
            let step = try candidate.apply(J4PayloadCodec.envelope(SchedulerTraceCodec.encodeInput(event)))
            XCTAssertThrowsError(try J4PayloadCodec.envelope(SchedulerTraceCodec.encodeStep(step)))
            XCTAssertThrowsError(try candidate.apply(.init(owner: "format-negative", ordinal: 3, input: .clear)))
            return
        }
        let directory = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("scheduler-input-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw SchedulerCandidateError.invalid("missing input family") }
        let outputRoot = directory.appending(path: "bucket-candidate", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: outputRoot.path)
        else { throw SchedulerCandidateError.invalid("reused candidate output") }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: false)
        var total = 0, ownerCount = 0, differences = 0
        var operationCounts: [String: Int] = [:]
        for inputFile in files {
            let suffix = inputFile.lastPathComponent.dropFirst("scheduler-input-".count)
            let nativeFile = directory.appending(path: "scheduler-native-" + suffix)
            let canonicalFile = outputRoot.appending(path: "inputs-" + suffix)
            let candidateFile = outputRoot.appending(path: "candidate-" + suffix)
            let diffFile = outputRoot.appending(path: "diff-" + suffix)
            for file in [canonicalFile, candidateFile, diffFile] {
                guard FileManager.default.createFile(atPath: file.path, contents: nil)
                else { throw SchedulerCandidateError.invalid("output exists") }
            }
            let canonical = try FileHandle(forWritingTo: canonicalFile),
                candidateLog = try FileHandle(forWritingTo: candidateFile),
                diffLog = try FileHandle(forWritingTo: diffFile)
            defer { try? canonical.close(); try? candidateLog.close(); try? diffLog.close() }
            var candidates: [String: SchedulerCandidate] = [:]
            var cold: [String: SchedulerCandidate] = [:]
            var projections: [String: ScenarioPayload] = [:]
            let data = try Data(contentsOf: inputFile)
            for line in data.split(separator: 10) {
                let payload = try J4PayloadCodec.payload(Data(line))
                let envelope = try J4PayloadCodec.envelope(payload: payload)
                let raw = try object(payload)
                operationCounts[try text(raw["operation"]), default: 0] += 1
                var instance = candidates[envelope.owner] ?? SchedulerCandidate()
                let step = try instance.apply(envelope); candidates[envelope.owner] = instance
                // The cold replay receives only the canonical input bytes, not this candidate state/output.
                var canonicalBytes = try SchedulerTraceCodec.encodeInput(envelope); canonicalBytes.append(10)
                try canonical.write(contentsOf: canonicalBytes)
                var independent = cold[envelope.owner] ?? SchedulerCandidate()
                let second = try independent
                    .apply(J4PayloadCodec.envelope(canonicalBytes)); cold[envelope.owner] = independent
                XCTAssertEqual(step,
                               second) // Full typed equality, including every opaque field/order, no hash or JSON normalization.
                var complete = try SchedulerTraceCodec.encodeStep(step); complete.append(10); try candidateLog
                    .write(contentsOf: complete)
                let projection: ScenarioPayload = .object([
                    "pending": .array(step.snapshot.queued.map(SchedulerTraceCodec.itemPayload)),
                    "drained": .array(step.proposals.filter { $0.cause == .drain }
                        .map { SchedulerTraceCodec.itemPayload($0.item) }),
                    "tokens": nullable(step.snapshot.tokens), "refill": nullable(step.snapshot.lastRefill),
                    "retry": nullable(step.snapshot.retryAfter),
                    "removed_keys": strings(step.removedKeys), "replaced_keys": strings(step.replacedKeys)
                ])
                let key = envelope.owner + ":" + String(envelope.ordinal)
                guard projections.updateValue(projection, forKey: key) == nil
                else { throw SchedulerCandidateError.ordinalMismatch }
                total += 1
            }
            ownerCount += candidates.count
            // Native output is opened only after the entire input-only candidate/cold replay above.
            let nativeData = try Data(contentsOf: nativeFile)
            var compared = Set<String>()
            for line in nativeData.split(separator: 10) {
                let raw = try object(J4PayloadCodec.payload(Data(line)))
                guard Set(raw.keys) == ["schema_version", "owner", "ordinal", "output"],
                      raw["schema_version"] == .scalar(.number(1))
                else { throw SchedulerCandidateError.invalid("native envelope fields") }
                let key = try text(raw["owner"]) + ":" + text(raw["ordinal"])
                guard compared.insert(key).inserted, let proposed = projections[key],
                      let native = raw["output"] else { throw SchedulerCandidateError.ordinalMismatch }
                guard Set(try object(native).keys) == [
                    "pending",
                    "drained",
                    "tokens",
                    "refill",
                    "retry",
                    "removed_keys",
                    "replaced_keys"
                ] else {
                    throw SchedulerCandidateError.invalid("native output fields")
                }
                let delta = SchedulerTraceDiff.compare(reference: native, candidate: proposed)
                for difference in delta {
                    try write(.object([
                        "association": .scalar(.text(key)),
                        "path": .scalar(.text(difference.path)),
                        "native": difference.reference ?? .scalar(.null),
                        "candidate": difference.candidate ?? .scalar(.null),
                        "native_present": .scalar(.flag(difference.reference != nil)),
                        "candidate_present": .scalar(.flag(difference.candidate != nil)),
                        "classification": .scalar(.text("unclassified_bucket_difference_requires_review"))
                    ]), to: diffLog)
                }
                differences += delta.count
            }
            guard compared.count == projections.count
            else { throw SchedulerCandidateError.invalid("missing native output") }
        }
        for operation in ["initialize", "enqueue", "cancel", "drain", "failure", "clear"] {
            guard operationCounts[operation, default: 0] > 0
            else { throw SchedulerCandidateError.invalid("missing operation " + operation) }
        }
        guard total > 0, ownerCount > 0 else { throw SchedulerCandidateError.invalid("empty archive") }
        let report: [String: Any] = [
            "scope": "FeedbackScheduler bucket/FIFO/merge only; not Session direct/gate/receipt",
            "input_operations": total,
            "owners": ownerCount,
            "operation_counts": operationCounts,
            "exact_bucket_differences": differences,
            "input_only_cold_replay": true,
            "whole_candidate_state_preserved": true,
            "native_used_as_state_seed": false
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: outputRoot.appending(path: "report.json"))
        XCTAssertEqual(
            differences,
            0,
            "Unclassified bucket difference: preserve complete report and ask supervisor; never reseed"
        )
    }
}
