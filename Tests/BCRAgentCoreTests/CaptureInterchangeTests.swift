import BCRFoundation
@testable import BCRSurfaceDomain
import BCRPersistenceAdapter
import Foundation
import XCTest

@MainActor
private final class CaptureFixtureClock { var value = 100.0 }

@MainActor
final class CaptureInterchangeTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/Capture")
    }

    private func sample() async throws -> Data {
        let clock = CaptureFixtureClock(), rotary = BCRControlID.encoder(row: 1, 1), nrpn = BCRControlID.pushEncoder(
            group: 1,
            1
        )
        var map = HardwareMap()
        try map.bind(rotary, to: .init(kind: .controlChange, channel: 0, number: 7))
        try map.bind(nrpn, to: .init(kind: .nrpn, channel: 15, number: 300))
        let config = SurfaceConfiguration(name: "Capture fixture", parameters: [
            .init(id: "x", name: "X"), .init(id: "y", name: "Y", maximum: 16383)
        ], assignments: [
            .init(control: rotary, target: .parameter("x")),
            .init(control: nrpn, target: .parameter("y"))
        ])
        let session = SurfaceSession(
            hardwareDevice: MockSurfaceDevice(),
            mockDevice: MockSurfaceDevice(model: MockBCR2000(preset: map)),
            configuration: config,
            now: { Date(timeIntervalSince1970: clock.value) },
            historyTime: .init(now: { clock.value }),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "sample.jsonl")
        let writer = MonitorCaptureWriter(url: url, header: try session.captureHeader(
            sessionID: "00000000-0000-4000-8000-000000000011", applicationVersion: "fixture-v1"
        ))
        let token = session.observeCapture { writer.append($0) }
        for index in 1 ... 5 {
            clock.value += 0.25; session.simulateAbsoluteInput(rotary, rawValue: UInt16(index * 10))
            clock.value += 0.25; session.setParameter("x", to: Double(index * 10 + 5))
        }
        clock.value += 0.25; session.setParameter("y", to: 1000)
        clock.value += 0.25
        writer.append(.sysEx(Data([0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0xF7]),
                             at: Date(timeIntervalSince1970: clock.value), monotonic: clock.value, source: .mock))
        session.removeCaptureObserver(token)
        clock.value += 0.25; writer.finish(session.captureEnd(eventCount: writer.snapshot.eventCount))
        let result = await writer.flush(); XCTAssertEqual(result.phase, .finished)
        return try Data(contentsOf: url)
    }

    func testRecorderMatchesCommittedSample() async throws {
        let data = try await sample(), file = fixtures.appending(path: "bcr-sample.jsonl")
        if ProcessInfo.processInfo.environment["BCR_UPDATE_CAPTURE_FIXTURES"] == "1" { try data.write(to: file) }
        XCTAssertEqual(data, try Data(contentsOf: file))
        let capture = try RecordedCapture(data: data)
        XCTAssertTrue(capture.review.isComplete)
        XCTAssertEqual(capture.events.count, 15)
        XCTAssertEqual(capture.events.filter { $0.fields["bcrNRPN"] != nil }.count, 4)
        XCTAssertEqual(capture.events.filter { $0.fields["sysEx"] != nil }.count, 1)
        XCTAssertTrue(capture.events.allSatisfy { $0.fields["source"] == .string("mock") })
        XCTAssertTrue(capture.events.allSatisfy { ($0.fields["rawMIDI1Bytes"]?.arrayValue?.count ?? 0) <= 3 })
        let replay = try RecordedCaptureReplay(capture: capture)
        while try replay.step() {}
        XCTAssertEqual(replay.recordedOutputsSkipped, 9)
        XCTAssertEqual(replay.inputsReplayed, 5)
    }

    func testCommittedXTouchSampleCommonFieldsAreReadableButReplayIsExplicitlyRefused() async throws {
        let bytes = try Data(contentsOf: fixtures.appending(path: "xtouch-sample.jsonl"))
        let capture = try RecordedCapture(data: bytes)
        XCTAssertEqual(capture.deviceModel, "X-TOUCH COMPACT")
        XCTAssertTrue(capture.isForeignDevice)
        XCTAssertTrue(capture.review.isComplete)
        XCTAssertEqual(capture.events.count, 14)
        XCTAssertEqual(capture.header?["session"]?.objectValue?["applicationVersion"], .string("fixture-v1"))
        XCTAssertEqual(capture.events.filter { $0.direction == "IN" }.count, 12)
        XCTAssertEqual(capture.events.filter { $0.direction == "OUT" }.count, 2)
        XCTAssertEqual(capture.review, CaptureIntegrityReview())
        XCTAssertEqual(capture.header?["session"]?.objectValue?["configuredGlobalReceiveChannel"], .number(2))
        XCTAssertEqual(
            capture.events.first?.fields["rawMIDI1Bytes"],
            .array([.number(176), .number(101), .number(127)])
        )
        XCTAssertThrowsError(try RecordedCaptureReplay(capture: capture)) {
            XCTAssertEqual($0 as? CaptureDocumentError, .foreignDevice("X-TOUCH COMPACT"))
        }
        XCTAssertEqual(try Data(contentsOf: fixtures.appending(path: "xtouch-sample.jsonl")), bytes)
    }
}
