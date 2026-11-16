import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import Foundation
import XCTest
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@MainActor
final class OfflineCaptureTests: XCTestCase {
    private func fixture() throws -> [MonitorCaptureRecord] {
        let session = SurfaceSession(hardwareDevice: MockSurfaceDevice(), configuration: .neutral(),
                                     historyTime: .init(now: { 10 }), saveHardwareMap: { _ in },
                                     saveConfiguration: { _ in })
        let header = try session.captureHeader(sessionID: "offline", applicationVersion: "test")
        return [header,
                .init(fields: ["kind": .string("event"), "sequence": .number(1), "monotonicTimestamp": .number(11),
                               "direction": .string("IN"), "source": .string("mock"), "ignored": .bool(false),
                               "rawMIDI1Bytes": .array([.number(0xB0), .number(1), .number(100)])]),
                .init(fields: ["kind": .string("event"), "sequence": .number(2), "monotonicTimestamp": .number(12),
                               "direction": .string("OUT"), "source": .string("application"), "ignored": .bool(false),
                               "rawMIDI1Bytes": .array([.number(0xB0), .number(1), .number(5)])]),
                .end(at: Date(timeIntervalSinceReferenceDate: 0), monotonic: 13, eventCount: 2)]
    }

    private func data(_ records: [MonitorCaptureRecord]) throws -> Data { try records
        .reduce(Data()) { try $0 + $1.encodedLine() }
    }

    func testCompleteCaptureInputsReplayButRecordedOutputDoesNotReachMock() throws {
        let capture = try RecordedCapture(data: data(fixture()))
        XCTAssertTrue(capture.review.isComplete)
        let replay = try RecordedCaptureReplay(capture: capture)
        XCTAssertTrue(try replay.step())
        let value = try XCTUnwrap(replay.session.engine.value(of: "general.1"))
        XCTAssertGreaterThan(value, 70)
        let feedback = replay.mock.receivedCount
        XCTAssertTrue(try replay.step())
        XCTAssertEqual(replay.session.engine.value(of: "general.1"), value)
        XCTAssertEqual(replay.mock.receivedCount, feedback)
        XCTAssertEqual(replay.recordedOutputsSkipped, 1)
        XCTAssertEqual(replay.inputsReplayed, 1)
        XCTAssertFalse(try replay.step())
        try replay.reset()
        XCTAssertEqual(replay.cursor, 0)
        XCTAssertEqual(replay.session.engine.value(of: "general.1"), 0)
        XCTAssertEqual(replay.session.source, .mock)
        XCTAssertFalse(replay.session.connection.isConnected)
    }

    func testIntegrityCountsVersionRegressionTruncationAndUnparseableLinesSeparately() throws {
        var records = try fixture()
        records[0].fields["schemaVersion"] = .number(2)
        records[2].fields["monotonicTimestamp"] = .number(9)
        let bytes = try data(Array(records.prefix(3))) + Data("not-json\n{partial".utf8)
        let capture = try RecordedCapture(data: bytes), review = capture.review
        XCTAssertFalse(review.isComplete)
        XCTAssertEqual(review.unsupportedVersions, 1)
        XCTAssertEqual(review.nonMonotonicTimestamps, 1)
        XCTAssertEqual(review.truncatedLines, 1)
        XCTAssertEqual(review.unparseableLines, 1)
        XCTAssertEqual(review.boundaryErrors, 1)
        XCTAssertThrowsError(try RecordedCaptureReplay(capture: capture))
    }

    func testSequenceMissingTimestampBadBytesAndTamperedContextCannotLookComplete() throws {
        var records = try fixture()
        records[1].fields["sequence"] = .number(4)
        records[1].fields["monotonicTimestamp"] = nil
        records[2].fields["rawMIDI1Bytes"] = .array([.number(0xB0), .number(200), .number(1)])
        var context = try XCTUnwrap(records[0].fields["session"]?.objectValue)
        context["mappingFingerprint"] = .string("tampered")
        records[0].fields["session"] = .object(context)
        let capture = try RecordedCapture(data: data(records))
        XCTAssertEqual(capture.review.sequenceErrors, 1)
        XCTAssertEqual(capture.review.invalidTimestamps, 1)
        XCTAssertEqual(capture.review.unparseableLines, 1)
        XCTAssertEqual(capture.review.contextErrors, 1)
        XCTAssertFalse(capture.review.isComplete)
        XCTAssertThrowsError(try RecordedCaptureReplay(capture: capture))
    }

    func testLivePrefixAndEventsAfterFooterAreInsufficientEvidence() throws {
        let records = try fixture()
        let prefix = try RecordedCapture(data: data(Array(records.prefix(2))))
        XCTAssertFalse(prefix.review.isComplete)
        XCTAssertEqual(prefix.review.boundaryErrors, 1)
        XCTAssertNoThrow(try RecordedCaptureReplay(capture: prefix))
        let extra = try RecordedCapture(data: data(records + [records[1]]))
        XCTAssertGreaterThan(extra.review.boundaryErrors, 0)
        XCTAssertFalse(extra.review.isComplete)
    }

    func testReadOnlyLoaderRejectsSymlinksFIFOsDirectoriesAndOversizedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "capture.jsonl"), original = try data(fixture())
        try original.write(to: file)
        XCTAssertTrue(try OfflineCaptureFile.load(file).review.isComplete)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let link = root.appending(path: "link"), fifo = root.appending(path: "fifo"),
            huge = root.appending(path: "huge")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try OfflineCaptureFile.load(link))
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try OfflineCaptureFile.load(fifo))
        XCTAssertThrowsError(try OfflineCaptureFile.load(root))
        try Data().write(to: huge)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(RecordedCapture.maximumBytes + 1)); try handle.close()
        XCTAssertThrowsError(try OfflineCaptureFile.load(huge))
        XCTAssertThrowsError(try OfflineCaptureFile.load(URL(string: "https://example.invalid/capture")!))
    }

    func testRelativeInputUsesCapturedInitialValueAndContextBoundaryChangesOnlyIsolatedMapping() throws {
        var config = SurfaceConfiguration.neutral()
        try config.assign(.init(control: .pushEncoder(group: 1, 1), target: .parameter("general.1"),
                                encoderMode: .relative1, encoderStep: 2))
        let source = SurfaceSession(hardwareDevice: MockSurfaceDevice(), configuration: config,
                                    historyTime: .init(now: { 10 }), saveHardwareMap: { _ in },
                                    saveConfiguration: { _ in })
        source.setParameter("general.1", to: 40)
        let header = try source.captureHeader(sessionID: "relative", applicationVersion: "test")
        var input = try fixture()[1]
        input.fields["rawMIDI1Bytes"] = .array([.number(0xB0), .number(1), .number(2)])
        let replay = try RecordedCaptureReplay(capture: RecordedCapture(data: data([
            header, input, .end(at: Date(timeIntervalSinceReferenceDate: 0), monotonic: 12, eventCount: 1)
        ])))
        XCTAssertEqual(replay.session.engine.value(of: "general.1"), 40)
        XCTAssertTrue(try replay.step())
        XCTAssertEqual(replay.session.engine.value(of: "general.1"), 44)

        try source.setAssignment(.init(control: .pushEncoder(group: 1, 1), target: .parameter("general.2")),
                                 for: .pushEncoder(group: 1, 1))
        var context = try source.captureHeader(sessionID: "relative", applicationVersion: "test")
        context.fields["kind"] = .string("event"); context.fields["origin"] = .string("contextChanged")
        context.fields["sequence"] = .number(1)
        input.fields["sequence"] = .number(2)
        input.fields["rawMIDI1Bytes"] = .array([.number(0xB0), .number(1), .number(127)])
        let changed = try RecordedCaptureReplay(capture: RecordedCapture(data: data([
            header, context, input, .end(at: Date(timeIntervalSinceReferenceDate: 0), monotonic: 12, eventCount: 2)
        ])))
        XCTAssertTrue(try changed.step()); XCTAssertTrue(try changed.step())
        XCTAssertEqual(changed.session.engine.value(of: "general.1"), 40)
        XCTAssertEqual(changed.session.engine.value(of: "general.2"), 100)
    }

    func testReplayNoteOffPreservesReleaseStateAndRejectsInvalidMessage() throws {
        var map = HardwareMap()
        let button = BCRControlID.button(row: 1, 1)
        try map.bind(button, to: .init(kind: .note, channel: 0, number: 1))
        var mock = MockBCR2000(preset: map)
        try mock.applyCapturedInput(.noteOn(channel: 0, number: 1, velocity: 127))
        XCTAssertEqual(mock.value(of: button), 127)
        try mock.applyCapturedInput(.noteOff(channel: 0, number: 1, velocity: 64))
        XCTAssertEqual(mock.value(of: button), 0)
        XCTAssertEqual(mock.sentCount, 2)
        XCTAssertThrowsError(try mock.applyCapturedInput(.controlChange(channel: 0, number: 200, value: 0)))
        XCTAssertEqual(mock.sentCount, 2)
    }
}
