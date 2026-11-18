import Foundation
import SurfaceDeviceConformance
import SurfaceFeedbackPlanning
import XCTest

private struct O4QueueStep: Equatable {
    let rate: FeedbackQueueRate
    let pending: [SchedulerItem]
    let drained: [SchedulerItem]
    let removed: [String]
    let replaced: [String]
    let tokens: Double?
    let refill: Double?
    let retry: Double?

    var nativeProjection: ScenarioPayload {
        func numbers(_ value: Double?) -> ScenarioPayload { value.map { .scalar(.number($0)) } ?? .scalar(.null) }
        func strings(_ value: [String]) -> ScenarioPayload { .array(value.map { .scalar(.text($0)) }) }
        return .object([
            "pending": .array(pending.map(SchedulerTraceCodec.itemPayload)),
            "drained": .array(drained.map(SchedulerTraceCodec.itemPayload)),
            "removed_keys": strings(removed), "replaced_keys": strings(replaced),
            "tokens": numbers(tokens), "refill": numbers(refill), "retry": numbers(retry)
        ])
    }
}

/// Drives the real product queue. This adapter owns only archive ordinals and projections.
private struct O4QueueDriver {
    private var queue: FeedbackQueue<String, SchedulerItem>?
    private var ordinal: UInt64 = 0

    mutating func apply(_ event: SchedulerEnvelope) throws -> O4QueueStep {
        guard event.ordinal == ordinal + 1 else { throw SchedulerCandidateError.ordinalMismatch }
        ordinal = event.ordinal
        if case let .initialize(.bucket(rate, burst, cooldown)) = event.input {
            guard queue == nil else { throw SchedulerCandidateError.alreadyInitialized }
            queue = try .init(rate: .bucket(perSecond: rate, burst: burst, failureCooldown: cooldown))
            return snapshot()
        }
        guard queue != nil else { throw SchedulerCandidateError.notInitialized }
        switch event.input {
        case let .enqueue(item, _):
            let previous = queue!.enqueue(item, for: item.key)
            return snapshot(replaced: previous.map { [$0.key] } ?? [])
        case let .cancel(key):
            let previous = queue!.cancel(key)
            return snapshot(removed: previous.map { [$0.key] } ?? [])
        case let .drain(instant):
            let drained = try queue!.drain(at: instant)
            return snapshot(drained: drained.map(\.item), removed: drained.map(\.key))
        case let .failure(instant):
            try queue!.noteFailure(at: instant)
            return snapshot()
        case .clear:
            let removed = queue!.clear()
            return snapshot(removed: removed)
        default:
            throw SchedulerCandidateError.invalid("not an original BCR bucket operation")
        }
    }

    private func snapshot(drained: [SchedulerItem] = [], removed: [String] = [],
                          replaced: [String] = []) -> O4QueueStep
    {
        let queue = queue!
        return .init(rate: queue.rate, pending: queue.orderedEntries.map(\.item), drained: drained,
                     removed: removed, replaced: replaced, tokens: queue.tokens, refill: queue.lastRefill,
                     retry: queue.retryAfter)
    }
}

/// Independent of the historical SchedulerCandidate, which keeps its original archive and classifications.
final class O4RuntimeQueueArchiveTests: XCTestCase {
    func testReplayOriginalBCRQueueInputsWithProductQueue() throws {
        guard let path = ProcessInfo.processInfo.environment["BCR_O4_QUEUE_ARCHIVE"] else {
            try exerciseQueueProjection()
            return
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let reportPath = ProcessInfo.processInfo.environment["BCR_O4_QUEUE_REPORT"] else {
            throw SchedulerCandidateError.invalid("missing independent queue proof report destination")
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let inputPrefix = "scheduler-input-", outputPrefix = "scheduler-native-"
        func periods(_ prefix: String) -> Set<String> {
            Set(files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jsonl" }
                .map { String($0.lastPathComponent.dropFirst(prefix.count)) })
        }
        let periodsWithInput = periods(inputPrefix)
        guard !periodsWithInput.isEmpty, periodsWithInput == periods(outputPrefix) else {
            throw SchedulerCandidateError.invalid("missing matching queue input/output files")
        }
        var expectedByFile: [String: [Data: ScenarioPayload]] = [:]
        var operationCounts = [String: Int](), ownerCount = 0
        for period in periodsWithInput.sorted() {
            let data = try Data(contentsOf: root.appending(path: inputPrefix + period))
            var current = [Data: O4QueueDriver](), cold = [Data: O4QueueDriver]()
            var expected = [Data: ScenarioPayload]()
            for line in data.split(separator: 10) {
                let payload = try J4PayloadCodec.payload(Data(line))
                let event = try J4PayloadCodec.envelope(payload: payload)
                let operation = try text(try object(payload)["operation"])
                operationCounts[operation, default: 0] += 1
                let step = try current[Data(event.owner.utf8), default: O4QueueDriver()].apply(event)
                let coldInput = try J4PayloadCodec.envelope(SchedulerTraceCodec.encodeInput(event))
                let coldStep = try cold[Data(coldInput.owner.utf8), default: O4QueueDriver()].apply(coldInput)
                let projection = step.nativeProjection
                guard event == coldInput, J4ExactJSON.envelope(event, coldInput), step == coldStep,
                      J4ExactJSON.same(projection, coldStep.nativeProjection)
                else { throw SchedulerCandidateError.invalid("current/cold mismatch \(event.owner):\(event.ordinal)") }
                let identifier = J4ExactJSON.identifier(owner: event.owner, ordinal: event.ordinal)
                guard expected.updateValue(projection, forKey: identifier) == nil else {
                    throw SchedulerCandidateError.ordinalMismatch
                }
            }
            ownerCount += current.count
            expectedByFile[period] = expected
        }

        let phases: Set<String> = ["initialize", "enqueue", "cancel", "drain", "failure", "clear"]
        guard Set(operationCounts.keys) == phases, ownerCount > 0 else {
            throw SchedulerCandidateError.invalid("incomplete original queue operations")
        }
        // Native output bytes are first opened after independent replay of all input files.
        var compared = 0, mismatches = 0
        for period in periodsWithInput.sorted() {
            var expected = expectedByFile[period]!
            let data = try Data(contentsOf: root.appending(path: outputPrefix + period))
            for line in data.split(separator: 10) {
                let row = try object(J4PayloadCodec.payload(Data(line)))
                guard Set(row.keys) == ["schema_version", "owner", "ordinal", "output"],
                      row["schema_version"] == .scalar(.number(1)), let output = row["output"]
                else {
                    throw SchedulerCandidateError.invalid("native queue result schema")
                }
                let owner = try text(row["owner"]), rawOrdinal = try text(row["ordinal"])
                guard let ordinal = UInt64(rawOrdinal), ordinal > 0, String(ordinal) == rawOrdinal,
                      let candidate = expected.removeValue(forKey: J4ExactJSON.identifier(
                          owner: owner,
                          ordinal: ordinal
                      ))
                else { throw SchedulerCandidateError.ordinalMismatch }
                if !J4ExactJSON.same(output, candidate) {
                    let paths = SchedulerTraceDiff.compare(reference: output, candidate: candidate).map(\.path)
                    mismatches += max(1, paths.count)
                    XCTFail("\(period)/\(owner):\(ordinal): \(paths.isEmpty ? ["scalar byte or bit identity"] : paths)")
                }
                compared += 1
            }
            guard expected.isEmpty else { throw SchedulerCandidateError.invalid("missing native results " + period) }
        }
        let report: [String: Any] = [
            "input_operations": operationCounts.values.reduce(0, +), "compared_operations": compared,
            "operation_counts": operationCounts, "owners": ownerCount, "exact_bucket_differences": mismatches,
            "input_only_cold_replay": true, "native_used_as_state_seed": false
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: reportPath), options: .withoutOverwriting)
        XCTAssertEqual(compared, operationCounts.values.reduce(0, +))
        XCTAssertEqual(mismatches, 0)
        print("O4 production queue: \(compared) operations, \(ownerCount) owners, \(mismatches) differences")
    }

    private func exerciseQueueProjection() throws {
        func item(_ key: String, _ value: String?, _ scope: String?) throws -> SchedulerItem {
            try .init(key: key, value: value.map { .scalar(.text($0)) } ?? .scalar(.null),
                      scope: scope.map { .scalar(.text($0)) } ?? .scalar(.null))
        }
        var driver = O4QueueDriver(), ordinal: UInt64 = 0
        func apply(_ input: SchedulerInput) throws -> O4QueueStep {
            ordinal += 1
            return try driver.apply(.init(owner: "projection", ordinal: ordinal, input: input))
        }
        let first = try item("midi.1.1", "first", nil), second = try item("midi.1.2", "second", "pinned")
        let replacement = try item(first.key, "changed", "new epoch")
        _ = try apply(.initialize(.bucket(perSecond: 1, burst: 1, errorCooldown: 2)))
        _ = try apply(.enqueue(first, ingress: .externalRequest))
        _ = try apply(.enqueue(second, ingress: .externalRequest))
        let replaced = try apply(.enqueue(replacement, ingress: .externalRequest))
        XCTAssertEqual(replaced.replaced, [first.key])
        XCTAssertEqual(replaced.pending, [replacement, second])
        var reordered = try object(replaced.nativeProjection)
        reordered["pending"] = .array([second, replacement].map(SchedulerTraceCodec.itemPayload))
        let orderMismatch = SchedulerTraceDiff.compare(
            reference: replaced.nativeProjection,
            candidate: .object(reordered)
        )
        XCTAssertTrue(orderMismatch.map(\.path).contains("$.pending[0].key"))
        let omittedScope = try item(replacement.key, "changed", nil)
        var lostScope = try object(replaced.nativeProjection)
        lostScope["pending"] = .array([omittedScope, second].map(SchedulerTraceCodec.itemPayload))
        XCTAssertEqual(SchedulerTraceDiff.compare(reference: replaced.nativeProjection, candidate: .object(lostScope))
            .map(\.path), ["$.pending[0].scope"])
        let firstDrain = try apply(.drain(at: -1))
        XCTAssertEqual(firstDrain.drained, [replacement])
        XCTAssertEqual(firstDrain.tokens, 0)
        XCTAssertEqual(try apply(.failure(at: -1)).tokens, 0)
        XCTAssertEqual(try apply(.drain(at: 0)).drained, [])
        XCTAssertEqual(try apply(.drain(at: -2)).tokens, 0)
        XCTAssertEqual(try apply(.drain(at: 1)).drained, [second])
        _ = try apply(.enqueue(first, ingress: .externalRequest))
        let cleared = try apply(.clear)
        XCTAssertEqual(cleared.removed, [first.key])
        XCTAssertEqual(cleared.pending, [])
        XCTAssertEqual(cleared.tokens, 1)
        XCTAssertNil(cleared.refill)
        XCTAssertNil(cleared.retry)
    }

    private func object(_ input: ScenarioPayload) throws -> [String: ScenarioPayload] {
        guard case let .object(value) = input else { throw SchedulerCandidateError.invalid("queue archive object") }
        return value
    }

    private func text(_ input: ScenarioPayload?) throws -> String {
        guard case let .scalar(.text(value)) = input
        else { throw SchedulerCandidateError.invalid("queue archive text") }
        return value
    }
}
