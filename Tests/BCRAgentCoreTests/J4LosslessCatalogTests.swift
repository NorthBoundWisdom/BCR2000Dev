import Foundation
import XCTest
import SurfaceDeviceConformance
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning

final class J4LosslessCatalogTests: XCTestCase {
    private let null = ScenarioPayload.scalar(.null)
    private func s(_ value: String) -> ScenarioPayload { .scalar(.text(value)) }
    private func read(_ path: URL) throws -> [ScenarioPayload] {
        try Data(contentsOf: path).split(separator: 10).map { try JSONDecoder().decode(
            ScenarioPayload.self,
            from: Data($0)
        ) }
    }

    private func object(_ value: ScenarioPayload) throws -> [String: ScenarioPayload] {
        guard case let .object(value) = value else { throw SchedulerCandidateError.invalid("object") }; return value
    }

    func testCompleteCatalogExpandsEveryRealStateAndRejectsMissingOrConflictingData() throws {
        let requested = ProcessInfo.processInfo.environment["BCR_J4_CATALOG_TEST_ROOT"]
        let root = requested.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
            .appending(path: "j4-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { if requested == nil { try? FileManager.default.removeItem(at: root) } }
        let owner = "actual-actor-not-remapped"
        let item = try SchedulerItem(key: "same-key", value: .object([
            "wire": .array([.scalar(.number(0)), .scalar(.number(127))]), "origin": s("interface"),
            "legacy_endpoint": null, "unknown_endpoint": s("unknown"), "native_time": .scalar(.number(-0.125)),
            "u64": s("18446744073709551615"), "literal_object": .object(["$catalog": s("not-an-archive-reference")])
        ]),
        scope: .object([
            "native_scope": s("epoch-exact"),
            "missing": null
        ]))
        let other = try SchedulerItem(
            key: item.key,
            value: .object(["wire": s("different"), "origin": s("remote")]),
            scope: item.scope
        )
        func plan(_ value: SchedulerItem) throws -> SchedulerTracePlan {
            try .init(reference: .object(["existing_id": s("reference")]), payload: value.value,
                      origin: .object(["actor": s(owner), "time": .scalar(.number(-1.25))]), scope: value.scope,
                      source: .hardware, endpointEvidence: .init(
                          endpointID: "unknown",
                          deviceID: nil,
                          connectionGeneration: UInt64.max,
                          transportOrigin: .unknown
                      ),
                      capturedEvidence: SchedulerTraceCodec.queuedEvidence(
                          for: value,
                          nativeDispatch: .object(["native_fact": null])
                      ),
                      targetID: value.key, affectedElements: ["declared-element"], classification: .display,
                      sideEffects: [], deliveryMode: .direct)
        }
        let native: ScenarioPayload = .object([
            "permission": .scalar(.flag(true)),
            "native_time": .scalar(.number(-3.0)),
            "optional": null
        ])
        var reducer = SchedulerCandidate(), expected: [SchedulerStep] = []
        var archive: J4LosslessCatalog? = try .init(directory: root, suffix: "fixture.jsonl")
        func apply(_ input: SchedulerInput) throws -> SchedulerStep {
            let envelope = SchedulerEnvelope(owner: owner, ordinal: UInt64(expected.count + 1), input: input,
                                             context: .object(
                                                 ["literal_context": .object(["$catalog": s("still-literal")])]
                                             ))
            let step = try reducer.apply(envelope); expected.append(step); try archive!.append(
                envelope,
                step: step
            ); return step
        }
        _ = try apply(.initialize(.bucket(perSecond: 10, burst: 2, errorCooldown: 0.25)))
        _ = try apply(.enqueue(item, ingress: .externalRequest))
        let first = try apply(.drain(at: -1)).proposals[0]
        let p1 = try plan(item)
        _ = try apply(.gate(.init(proposalOrdinal: first.ordinal, proposedItem: item, dispatchPlan: p1,
                                  proof: .init(
                                      plan: p1,
                                      nativeSnapshot: native,
                                      authorization: .denied(reason: "actual denial"),
                                      safety: .rejected(reason: "unexecuted")
                                  ),
                                  currentScope: item.scope, currentNativeSnapshot: native)))
        let released = try apply(.release(key: item.key)).proposals[0]
        let p2 = try plan(item)
        _ = try apply(.gate(.init(proposalOrdinal: released.ordinal, proposedItem: item, dispatchPlan: p2,
                                  proof: .init(
                                      plan: p2,
                                      nativeSnapshot: native,
                                      authorization: .granted(directions: [.display]),
                                      safety: .passed
                                  ),
                                  currentScope: item.scope, currentNativeSnapshot: native)))
        _ = try apply(.receipt(.init(item: item, dispatchPlan: p2, result: .accepted, currentScope: item.scope)))
        _ = try apply(.requestDirect(item))
        let changed = try apply(.requestDirect(other)).proposals[0]
        let p3 = try plan(other)
        _ = try apply(.gate(.init(proposalOrdinal: changed.ordinal, proposedItem: other, dispatchPlan: p3,
                                  proof: .init(
                                      plan: p3,
                                      nativeSnapshot: native,
                                      authorization: .granted(directions: [.display]),
                                      safety: .passed
                                  ),
                                  currentScope: other.scope,
                                  currentNativeSnapshot: .object(["different_fact": .scalar(.flag(true))]))))
        _ = try apply(.failure(at: 0))
        _ = try apply(.receipt(.init(
            item: other,
            dispatchPlan: p3,
            result: .rejected(reason: "unmatched real boundary"),
            currentScope: other.scope
        )))
        _ = try apply(.clear)
        XCTAssertTrue(expected.contains { !$0.snapshot.awaitingGate.isEmpty })
        XCTAssertTrue(expected.contains { !$0.snapshot.awaitingReceipt.isEmpty })
        XCTAssertTrue(expected.contains { !$0.snapshot.withheld.isEmpty })
        XCTAssertTrue(expected.contains { !$0.snapshot.desired.isEmpty })
        XCTAssertTrue(expected.contains { !$0.snapshot.acceptedCache.isEmpty })
        XCTAssertTrue(expected.contains { !$0.snapshot.persistentAlignmentDifferences.isEmpty })
        XCTAssertTrue(expected.contains { $0.snapshot.retryAfter != nil })
        archive = nil
        let catalogs = try read(root.appending(path: "catalog-fixture.jsonl"))
        let outputs = try read(root.appending(path: "candidate-catalog-fixture.jsonl"))
        let inputs = try Data(contentsOf: root.appending(path: "inputs-fixture.jsonl")).split(separator: 10)
            .map { try SchedulerTraceCodec.decodeInput(Data($0)) }
        XCTAssertEqual(outputs.count, expected.count)
        var expander = J4CatalogExpander()
        for value in catalogs { try expander.add(value) }
        for index in outputs.indices {
            let restored = try expander.step(outputs[index], input: inputs[index])
            let canonical = try JSONDecoder().decode(
                ScenarioPayload.self,
                from: SchedulerTraceCodec.encodeStep(expected[index])
            )
            XCTAssertEqual(restored, canonical, "Full original49ad encodeStep at ordinal \(index + 1)")
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let process = Process(), diagnostics = Pipe(),
                expanded = root.appending(path: "cli-expanded-" + String(index + 1) + ".json")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3",
                repository.appending(path: "Tests/J4Support/expand_catalog.py").path,
                root.path,
                "--suffix",
                "fixture.jsonl",
                "--owner",
                owner,
                "--ordinal",
                String(index + 1),
                "--output",
                expanded.path
            ]
            process.standardOutput = diagnostics; process.standardError = diagnostics
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(
                process.terminationStatus,
                0,
                String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
            let cliResult = try JSONDecoder().decode(ScenarioPayload.self, from: Data(contentsOf: expanded))
            XCTAssertEqual(
                cliResult,
                canonical,
                "Actual Python CLI full encodeStep equivalence at ordinal \(index + 1)"
            )
        }
        func fresh() throws
            -> J4CatalogExpander
        {
            var result = J4CatalogExpander(); for value in catalogs { try result.add(value) }; return result
        }
        var duplicate = try fresh(); XCTAssertThrowsError(try duplicate.add(catalogs[0]))
        var gap = try fresh(); XCTAssertThrowsError(try gap.step(outputs[1], input: inputs[1]))
        var unknownSchema = try object(outputs[0]); unknownSchema["artifact"] = s("unknown-schema")
        var invalidSchema = try fresh(); XCTAssertThrowsError(try invalidSchema.step(
            .object(unknownSchema),
            input: inputs[0]
        ))
        var broken = try object(outputs[0]), delta = try object(try object(outputs[0])["state_delta"]!)
        delta.removeValue(forKey: "desired"); broken["state_delta"] = .object(delta)
        var missingField = try fresh(); XCTAssertThrowsError(try missingField.step(.object(broken), input: inputs[0]))
        delta = try object(try object(outputs[0])["state_delta"]!)
        delta["queued"] = .object([
            "replace": .array([.object(["$catalog": s("missing-id")])])
        ]); broken["state_delta"] =
            .object(delta)
        var missingRef = try fresh(); XCTAssertThrowsError(try missingRef.step(.object(broken), input: inputs[0]))
    }
}
