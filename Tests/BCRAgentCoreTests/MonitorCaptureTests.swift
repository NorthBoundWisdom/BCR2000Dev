import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import BCRTimingTestSupport
import Foundation
import XCTest

private enum CaptureTestError: Error { case injected }
private final class CaptureTestSink: CaptureEvidenceSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    private var blocked = false
    private var closed = false
    let gate: DispatchSemaphore?
    let failAfter: Int?
    init(gate: DispatchSemaphore? = nil, failAfter: Int? = nil) { self.gate = gate; self.failAfter = failAfter }
    var isBlocked: Bool { lock.withLock { blocked } }
    var data: Data { lock.withLock { lines.reduce(Data(), +) } }
    var isClosed: Bool { lock.withLock { closed } }
    func write(_ data: Data) throws {
        let count = lock.withLock { lines.count }
        if count == 0, let gate { lock.withLock { blocked = true }; gate.wait() }
        if let failAfter, count >= failAfter { throw CaptureTestError.injected }
        lock.withLock { lines.append(data) }
    }

    func synchronize() throws {}
    func close() throws { lock.withLock { closed = true } }
}

@MainActor
private final class CaptureTestDevice: SurfaceSysExObserving {
    var connection = MIDIConnectionSnapshot(connectedSource: "in", connectedDestination: "out")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var onSysExObservation: (@MainActor (Data) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
}

@MainActor
final class MonitorCaptureTests: XCTestCase {
    private func session(_ device: CaptureTestDevice) -> SurfaceSession {
        let config = SurfaceConfiguration(name: "test", parameters: [.init(id: "x", name: "X")], assignments: [
            .init(control: .pushEncoder(group: 1, 1), target: .parameter("x")),
            .init(control: .encoder(row: 1, 1), target: .parameter("x"))
        ])
        return SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(), configuration: config,
                              now: { Date(timeIntervalSinceReferenceDate: 1_000) }, historyTime: .init(now: { 42 }),
                              saveHardwareMap: { _ in }, saveConfiguration: { _ in })
    }

    private func rows(_ data: Data) throws -> [[String: JSONValue]] {
        try data.split(separator: 10)
            .map { try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data($0)).objectValue) }
    }

    func testSHA256StandardVectors() async {
        XCTAssertEqual(ContentDigest.sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            ContentDigest.sha256(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(ContentDigest.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testRecordingIsIndependentOfMonitorRingAndPreservesDeviceBytes() async throws {
        var sequences: [[MIDIVoiceMessage]] = []
        for recording in [false, true] {
            let device = CaptureTestDevice(), s = session(device)
            s.selectSource(.hardware); device.sent.removeAll()
            let sink = CaptureTestSink()
            let header = try s.captureHeader(sessionID: "test", applicationVersion: "1.2.3")
            let writer = MonitorCaptureWriter(
                url: URL(fileURLWithPath: "/unused"),
                header: header,
                sinkFactory: { _ in sink }
            )
            let token = recording ? s.observeCapture { writer.append($0) } : nil
            for value in 1 ... 160 {
                device.onMessages?([.controlChange(channel: 0, number: 1, value: UInt8(value % 127))])
            }
            sequences.append(device.sent)
            writer.finish(s.captureEnd(eventCount: writer.snapshot.eventCount))
            let state = await writer.flush()
            XCTAssertEqual(state.phase, .finished)
            if let token { s.removeCaptureObserver(token) }
            if recording {
                let records = try rows(sink.data)
                XCTAssertGreaterThan(state.eventCount, 300)
                XCTAssertEqual(s.events.count, 300)
                XCTAssertEqual(records.first?["kind"], .string("capture-start"))
                XCTAssertEqual(records.first?["schemaVersion"], .number(1))
                XCTAssertEqual(records.first?["session"]?.objectValue?["applicationVersion"], .string("1.2.3"))
                XCTAssertEqual(records.last?["eventCount"], .number(state.eventCount))
                let eventRows = records.filter { $0["kind"] == .string("event") }
                XCTAssertEqual(eventRows.compactMap { $0["sequence"]?.exactIntValue }, Array(1 ... state.eventCount))
                let input = try XCTUnwrap(records.first { $0["direction"] == .string("IN") })
                XCTAssertEqual(input["monotonicTimestamp"], .number(42))
                XCTAssertNotNil(input["rawMIDI1Bytes"])
                XCTAssertNotNil(input["decoded"])
            }
        }
        XCTAssertFalse(sequences[0].isEmpty)
        XCTAssertEqual(sequences[0].map(\.midi1Bytes), sequences[1].map(\.midi1Bytes))
    }

    func testSlowDiskFailsBoundedRecordingButMIDIContinues() async throws {
        let gate = DispatchSemaphore(value: 0), sink = CaptureTestSink(gate: gate)
        let device = CaptureTestDevice(), s = session(device)
        let writer = MonitorCaptureWriter(url: URL(fileURLWithPath: "/unused"),
                                          header: try s.captureHeader(sessionID: "slow", applicationVersion: "test"),
                                          capacity: 2, sinkFactory: { _ in sink })
        let token = s.observeCapture { writer.append($0) }
        defer { s.removeCaptureObserver(token) }
        try await waitUntil("background disk write blocked") { sink.isBlocked }
        for value in 1 ... 20 { s.turn(.pushEncoder(group: 1, 1), by: value) }
        XCTAssertEqual(writer.snapshot.phase, .failed)
        XCTAssertNotNil(writer.snapshot.error)
        XCTAssertGreaterThan(s.engine.value(of: "x")!, 0, "MIDI work finishes before disk is released")
        gate.signal()
        _ = await writer.flush()
        XCTAssertFalse(String(decoding: sink.data, as: UTF8.self).contains("capture-end"))
    }

    func testWriteFailureCannotProduceCompletedFooter() async throws {
        let sink = CaptureTestSink(failAfter: 1), device = CaptureTestDevice(), s = session(device)
        let writer = MonitorCaptureWriter(url: URL(fileURLWithPath: "/unused"),
                                          header: try s.captureHeader(sessionID: "fail", applicationVersion: "test"),
                                          sinkFactory: { _ in sink })
        writer.append(.sysEx(Data([0xF0, 0, 0xF7]), at: Date(timeIntervalSinceReferenceDate: 0), monotonic: 1))
        writer.finish(s.captureEnd(eventCount: 1))
        let state = await writer.flush()
        XCTAssertEqual(state.phase, .failed); XCTAssertNotNil(state.error)
        XCTAssertTrue(sink.isClosed)
        XCTAssertFalse(String(decoding: sink.data, as: UTF8.self).contains("capture-end"))
    }

    func testSysExIsRedactedAndNRPNKeepsCanonicalBytes() async throws {
        let device = CaptureTestDevice(), s = session(device)
        var records: [MonitorCaptureRecord] = []
        let token = s.observeCapture { records.append($0) }
        defer { s.removeCaptureObserver(token) }
        let secretPreset = Data([0xF0] + Array("PERSONAL PRESET".utf8) + [0xF7])
        device.onSysExObservation?(secretPreset)
        let record = try XCTUnwrap(records.last)
        XCTAssertEqual(record.fields["sysEx"]?.objectValue?["byteCount"], .number(secretPreset.count))
        XCTAssertEqual(record.fields["sysEx"]?.objectValue?["sha256"], .string(ContentDigest.sha256(secretPreset)))
        XCTAssertNil(record.fields["rawMIDI1Bytes"])
        XCTAssertFalse(String(decoding: try record.encodedLine(), as: UTF8.self).contains("PERSONAL"))
        try s.setMockNRPN(true, for: .pushEncoder(group: 1, 1))
        s.setParameter("x", to: 100)
        let nrpn = try XCTUnwrap(records.last { $0.fields["decoded"]?.objectValue?["kind"] == .string("nrpn") })
        XCTAssertEqual(nrpn.fields["rawMIDI1Bytes"]?.arrayValue?.count, 12)
    }

    func testExclusiveEvidenceNeverOverwritesExistingFileOrSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "capture.jsonl"), link = root.appending(path: "link.jsonl")
        let sink = try CaptureEvidenceFile(url: file)
        try sink.write(Data("original".utf8)); try sink.close()
        XCTAssertThrowsError(try CaptureEvidenceFile(url: file))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try CaptureEvidenceFile(url: link))
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }
}
