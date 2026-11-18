import BCRFoundation
import BCRConfigurationAdapter
import BCRSurfaceDomain
import BCRCoreMIDIDriver
import BCRTimingTestSupport
import struct ParameterOutputPlugin.ParameterOutputFrame
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class OfflineIsolationMIDI: MIDIService {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent = 0
    var starts = 0
    func start() throws { starts += 1 }
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws { sent += 1 }
}

@MainActor
private final class OfflineIsolationOutput: OutputTransport {
    var isConnected = false
    var onSamples: (@MainActor ([ParameterObservation]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var frames: [ParameterOutputFrame] = []
    func start(host: String, port: UInt16) throws { isConnected = true }
    func ping(at now: Date) throws {}
    func send(_ frame: ParameterOutputFrame) throws { frames.append(frame) }
    func stop() { isConnected = false }
}

@MainActor
final class OfflineCaptureWorkspaceTests: XCTestCase {
    private func fixture() throws -> Data {
        let source = SurfaceSession(hardwareDevice: MockSurfaceDevice(), configuration: .neutral(),
                                    historyTime: .init(now: { 10 }), saveHardwareMap: { _ in },
                                    saveConfiguration: { _ in })
        var records = [try source.captureHeader(sessionID: "offline-test", applicationVersion: "test")]
        for sequence in 1 ... 300 {
            records.append(.init(fields: ["kind": .string("event"), "sequence": .number(sequence),
                                          "monotonicTimestamp": .number(10 + sequence),
                                          "direction": .string(sequence % 2 == 0 ? "OUT" : "IN"),
                                          "source": .string(sequence % 2 == 0 ? "application" : "mock"),
                                          "ignored": .bool(false),
                                          "rawMIDI1Bytes": .array([
                                              .number(0xB0),
                                              .number(1),
                                              .number(sequence % 128)
                                          ])]))
        }
        records.append(.end(at: Date(timeIntervalSinceReferenceDate: 0), monotonic: 311, eventCount: 300))
        return try records.reduce(Data()) { try $0 + $1.encodedLine() }
    }

    func testImportStepRunPauseResetAndClearCannotTouchLiveStateOrOpenMIDI() async throws {
        let midi = OfflineIsolationMIDI(), transport = OfflineIsolationOutput()
        let model = ConsoleViewModel(
            stores: .temporary(),
            startsMIDI: false,
            midiService: midi,
            outputTransport: transport,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
        model.setParameter("general.1", to: 71)
        let values = model.engine.parameterValues, runtime = model.provider.runtime.epoch
        let mapping = model.configuration, output = model.output.settings, monitor = model.events
        let externalFrames = transport.frames
        let offline = model.offlineCapture
        offline.importData(try fixture(), name: "fixture.jsonl")
        XCTAssertTrue(offline.loaded?.review.isComplete == true)
        XCTAssertFalse(offline.replay?.session === model.deviceWork.session)
        offline.step(); XCTAssertEqual(offline.replay?.cursor, 1)
        offline.run(); offline.pause()
        let paused = offline.replay?.cursor
        await Task.yield()
        XCTAssertEqual(offline.replay?.cursor, paused)
        offline.reset(); XCTAssertEqual(offline.replay?.cursor, 0)
        offline.run()
        try await waitUntil("offline replay finishes") { !offline.isPlaying }
        XCTAssertEqual(offline.replay?.inputsReplayed, 150)
        XCTAssertEqual(offline.replay?.recordedOutputsSkipped, 150)
        XCTAssertEqual(model.engine.parameterValues, values)
        XCTAssertEqual(model.provider.runtime.epoch, runtime)
        XCTAssertEqual(model.configuration, mapping)
        XCTAssertEqual(model.output.settings, output)
        XCTAssertEqual(model.events, monitor)
        XCTAssertEqual(midi.starts, 0); XCTAssertEqual(midi.sent, 0)
        XCTAssertEqual(transport.frames, externalFrames)
        XCTAssertFalse(model.output.settings.enabled)
        XCTAssertNil(model.deviceWork.session.motionSafety?.outputs.first)
        offline.clear(); XCTAssertNil(offline.loaded); XCTAssertNil(offline.replay)
    }

    func testMalformedImportPresentsReviewAndOversizeFailureKeepsPriorResult() throws {
        let controller = OfflineCaptureController()
        controller.importData(Data("not-json\n{partial".utf8), name: "damaged.jsonl")
        XCTAssertEqual(controller.loaded?.review.unparseableLines, 1)
        XCTAssertEqual(controller.loaded?.review.truncatedLines, 1)
        XCTAssertNil(controller.replay)
        XCTAssertNotNil(controller.error)
        controller.importData(try fixture(), name: "valid.jsonl")
        let capture = controller.loaded
        controller.importData(Data(repeating: 0, count: RecordedCapture.maximumBytes + 1), name: "too-large.jsonl")
        XCTAssertEqual(controller.loaded, capture)
        XCTAssertEqual(controller.name, "valid.jsonl")
        XCTAssertNotNil(controller.error)
    }
}
