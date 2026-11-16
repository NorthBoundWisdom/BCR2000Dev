import BCRFoundation
@testable import BCRSurfaceDomain
import BCRPersistenceAdapter
import Foundation
import XCTest

@MainActor
private final class CoverageDevice: SurfaceDevice {
    let connection = MIDIConnectionSnapshot(connectedSource: "input", connectedDestination: "output")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
}

@MainActor
final class InputCoverageTests: XCTestCase {
    func testAll108ControlsAreObservedWith56EncoderPositionsAndNoSends() throws {
        let device = CoverageDevice()
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(), configuration: .neutral(),
                                     hardwareOutput: .observe, saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.selectSource(.hardware)
        var coverage = InputCoverage()
        let token = session.observeMonitor { event, echo in coverage.observe(
            event,
            feedbackEcho: echo,
            map: session.learnedHardwareMap
        ) }
        defer { session.removeMonitorObserver(token) }
        let map = session.learnedHardwareMap
        for (index, control) in BCRLayout.allControls.enumerated() {
            let midi = try XCTUnwrap(map.midi(for: control))
            device.onMessages?([.controlChange(
                channel: midi.channel,
                number: UInt8(midi.number),
                value: UInt8(index + 1)
            )])
        }
        XCTAssertEqual(BCRLayout.allControls.count, 108)
        XCTAssertEqual(BCRLayout.allControls.filter(\.isContinuous).count, 56)
        XCTAssertEqual(coverage.messageCount, 108)
        XCTAssertEqual(coverage.observedControlCount, 108)
        XCTAssertTrue(BCRLayout.allControls.allSatisfy { coverage.review($0).matches(map.midi(for: $0)) == true })
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testNRPNCombinesFourCanonicalCCsAndUnmappedInputNeverGuessesControl() throws {
        var map = HardwareMap.mockPreset()
        let control = BCRControlID.pushEncoder(group: 1, 1)
        try map.bind(control, to: .init(kind: .nrpn, channel: 15, number: 300))
        let device = CoverageDevice()
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: map, configuration: .neutral(),
                                     hardwareOutput: .observe,
                                     now: { Date(timeIntervalSinceReferenceDate: 100) }, historyTime: .init(now: { 1 }),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.selectSource(.hardware)
        var coverage = InputCoverage()
        let token = session.observeMonitor { event, echo in coverage.observe(event, feedbackEcho: echo, map: map) }
        defer { session.removeMonitorObserver(token) }
        let bytes = MIDIVoiceMessage.nrpn(channel: 15, number: 300, value: 3000).midi1Bytes
        device.onMessages?(stride(from: 0, to: bytes.count, by: 3).map {
            .controlChange(channel: 15, number: bytes[$0 + 1], value: bytes[$0 + 2])
        })
        XCTAssertEqual(coverage.messageCount, 4)
        XCTAssertEqual(coverage.review(control).eventCount, 1)
        XCTAssertEqual(coverage.review(control).latestValue, 3000)
        device.onMessages?([.controlChange(channel: 0, number: 127, value: 1)])
        XCTAssertEqual(coverage.unmappedMessageCount, 1)
        XCTAssertEqual(coverage.observedControlCount, 1)
        let original = stride(from: 0, to: bytes.count, by: 3).map {
            MIDIVoiceMessage.controlChange(channel: 15, number: bytes[$0 + 1], value: bytes[$0 + 2])
        }
        device.onMessages?(Array(original.prefix(2)))
        try map.bind(control, to: .init(kind: .nrpn, channel: 15, number: 301))
        try session.installHardwareMap(map)
        device.onMessages?(Array(original.suffix(2)))
        XCTAssertEqual(coverage.review(control).eventCount, 1, "A changed map cannot complete an old partial NRPN")
        let next = MIDIVoiceMessage.nrpn(channel: 15, number: 301, value: 3000).midi1Bytes
        device.onMessages?(stride(from: 0, to: next.count, by: 3).map {
            .controlChange(channel: 15, number: next[$0 + 1], value: next[$0 + 2])
        })
        XCTAssertEqual(coverage.review(control).eventCount, 2)
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testMappingComparisonUsesLastObservedIdentityAndEchoDoesNotBecomeManualEvidence() throws {
        let device = CoverageDevice(), control = BCRControlID.pushEncoder(group: 1, 1)
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(), configuration: .neutral(),
                                     now: { Date(timeIntervalSinceReferenceDate: 100) }, historyTime: .init(now: { 1 }),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        session.selectSource(.hardware)
        var coverage = InputCoverage(), capture: [MonitorCaptureRecord] = []
        let token = session.observeMonitor { event, echo in coverage.observe(
            event,
            feedbackEcho: echo,
            map: session.learnedHardwareMap
        ) }
        let captureToken = session.observeCapture { capture.append($0) }
        defer { session.removeMonitorObserver(token); session.removeCaptureObserver(captureToken) }
        device.onMessages?([.controlChange(channel: 0, number: 1, value: 0)]) // Echo of initial feedback.
        XCTAssertEqual(coverage.echoCount, 1)
        XCTAssertEqual(coverage.observedControlCount, 0)
        XCTAssertEqual(capture.last?.fields["ignored"], .bool(true))
        device.onMessages?([.controlChange(channel: 0, number: 1, value: 40)])
        var changed = session.learnedHardwareMap
        try changed.bind(control, to: .init(kind: .controlChange, channel: 0, number: 120))
        XCTAssertEqual(coverage.review(control).matches(changed.midi(for: control)), false)
        XCTAssertEqual(coverage.review(control).latestValue, 40)
    }

    func testExportCoversEveryControlWithIndependentContentAndMappingFingerprints() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "review.json"), map = HardwareMap.mockPreset()
        let receipt = try InputReviewExporter.export(to: url, coverage: .init(), map: map, applicationVersion: "1.2.3",
                                                     source: .hardware, connection: .init(),
                                                     observationStarted: Date(timeIntervalSinceReferenceDate: 0),
                                                     generatedAt: Date(timeIntervalSinceReferenceDate: 1),
                                                     contextID: "fixed")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(receipt.sha256, ContentDigest.sha256(data))
        let report = try JSONDecoder().decode(JSONValue.self, from: data).objectValue!
        let groups = try XCTUnwrap(report["groups"]?.arrayValue)
        let controls = groups.flatMap { $0.objectValue?["controls"]?.arrayValue ?? [] }
        XCTAssertEqual(controls.count, 108)
        XCTAssertEqual(report["currentContext"]?.objectValue?["applicationVersion"], .string("1.2.3"))
        XCTAssertEqual(report["currentContext"]?.objectValue?["deviceSource"], .string("hardware"))
        XCTAssertNotNil(report["currentContext"]?.objectValue?["mappingFingerprint"]?.stringValue)
        XCTAssertEqual(report["hardwareAcceptance"], .null)
        XCTAssertTrue(try String(contentsOf: url.appendingPathExtension("sha256"), encoding: .utf8)
            .hasPrefix(receipt.sha256))
        XCTAssertThrowsError(try InputReviewExporter.export(
            to: url,
            coverage: .init(),
            map: map,
            applicationVersion: "test",
            source: .mock,
            connection: .init(),
            observationStarted: Date(timeIntervalSinceReferenceDate: 0),
            generatedAt: Date(timeIntervalSinceReferenceDate: 1),
            contextID: "fixed"
        ))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
