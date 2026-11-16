@testable import BCRSurfaceDomain
import BCRFoundation
import Foundation
import XCTest

final class SurfaceKernelShadowTests: XCTestCase {
    func testAuditGateFailsOnReorderedIDsAndChangedOptionalIdentity() throws {
        let environment = ProcessInfo.processInfo.environment
        if let mutation = environment["BCR_J3_NEGATIVE_CHILD"] {
            let native: [String: Any] = mutation == "order" ?
                ["ids": ["first", "second"]] : ["source": NSNull(), "context": NSNull(), "origin": NSNull()]
            let candidate: [String: Any] = mutation == "order" ?
                ["ids": ["second", "first"]] : ["source": "unknown", "context": NSNull(), "origin": NSNull()]
            SurfaceKernelAudit.compare("negative." + mutation, input: ["expected_mismatch": true],
                                       native: native, candidate: candidate)
            XCTFail("The actual Debug runtime mismatch gate failed to terminate the child")
            return
        }
        let root = environment["BCR_J3_SHADOW_ROOT"].map { URL(fileURLWithPath: $0) } ??
            FileManager.default.temporaryDirectory.appendingPathComponent("bcr-j3-audit-\(UUID().uuidString)")
        for mutation in ["order", "optional"] {
            let directory = root.appendingPathComponent("expected-negative/\(mutation)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("child.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
            let log = try FileHandle(forWritingTo: output)
            defer { try? log.close() }
            let child = Process()
            let identifier = "BCRAgentCoreTests.SurfaceKernelShadowTests/testAuditGateFailsOnReorderedIDsAndChangedOptionalIdentity"
            #if os(macOS)
                child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                child.arguments = ["xctest", "-XCTest", identifier, Bundle(for: Self.self).bundleURL.path]
            #else
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = [identifier]
            #endif
            child.environment = environment.merging([
                "BCR_J3_NEGATIVE_CHILD": mutation, "BCR_J3_SHADOW_ROOT": directory.path
            ]) { _, new in new }
            child.standardOutput = log; child.standardError = log
            try child.run(); child.waitUntilExit()
            XCTAssertNotEqual(child.terminationStatus, 0)
            XCTAssertTrue(try String(contentsOf: output, encoding: .utf8)
                .contains("J3 independent runtime shadow mismatch"))
            let raw = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }
            XCTAssertEqual(raw.count, 1)
            let rows = try Data(contentsOf: XCTUnwrap(raw.first)).split(separator: 10)
            XCTAssertEqual(rows.count, 1)
            let record = try XCTUnwrap(JSONSerialization
                .jsonObject(with: Data(XCTUnwrap(rows.first))) as? [String: Any])
            XCTAssertEqual(record["matches"] as? Bool, false)
            XCTAssertEqual(record["operation"] as? String, "negative." + mutation)
            XCTAssertNotEqual(String(reflecting: record["native"]), String(reflecting: record["candidate"]))
        }
    }

    func testFirstMatchKeepsDistinctLogicalFacetsOfOnePhysicalRole() {
        let first = BCRControlID.pushEncoder(group: 1, 1), second = BCRControlID.pushEncoder(group: 2, 1)
        let assignments: [ControlAssignment] = [
            .init(control: first, target: .parameter("p")),
            .init(control: first, target: .parameter("q")),
            .init(control: second, target: .parameter("q"))
        ]
        let configuration = SurfaceConfiguration(name: "fixture", parameters: [
            .init(id: "p", name: "p"), .init(id: "q", name: "q")
        ], assignments: assignments)
        XCTAssertEqual(configuration.assignment(for: first)?.target, .parameter("p"))
        XCTAssertEqual(configuration.assignment(for: second)?.target, .parameter("q"))
        XCTAssertNil(configuration.assignment(for: .pushEncoder(group: 3, 1)))
    }

    func testIndexRetainsFullOptionalScopeWhenSameIDIsReplacedWithoutReordering() throws {
        var scheduler = try FeedbackScheduler(policy: .init(enabled: true, messagesPerSecond: 10, burst: 1))
        let one = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 1)
        let newest = MIDIVoiceMessage.controlChange(channel: 0, number: 81, value: 9)
        let two = MIDIVoiceMessage.controlChange(channel: 0, number: 82, value: 2)
        let endpoint = MIDIEndpointSource(endpointID: "unknown", connectionGeneration: 7, provenance: .unknown)
        let context = SurfaceEventContext(generation: "actual-epoch", mappingGeneration: 3)
        scheduler.enqueue(one, origin: .software)
        scheduler.enqueue(two, origin: .external, endpoint: endpoint, mappingRevision: 3, source: .hardware,
                          context: context)
        scheduler.enqueue(newest, origin: .agent, endpoint: endpoint, mappingRevision: 3, source: .hardware,
                          context: context)
        XCTAssertEqual(scheduler.pendingItems.map(\.message), [newest, two])
        XCTAssertEqual(scheduler.pendingItems.map(\.context), [context, context])
        XCTAssertEqual(scheduler.pendingItems.map(\.source), [.hardware, .hardware])
        let drained = scheduler.drain(at: Date(timeIntervalSinceReferenceDate: 123))
        XCTAssertEqual(drained.map(\.message), [newest])
        XCTAssertEqual(drained.first?.endpoint, endpoint)
        scheduler.cancel(one.controlID)
        XCTAssertEqual(scheduler.pendingItems.map(\.message), [two])
        scheduler.clear()
        XCTAssertTrue(scheduler.pendingItems.isEmpty)
    }
}
