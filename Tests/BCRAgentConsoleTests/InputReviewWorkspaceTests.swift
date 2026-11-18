import BCRFoundation
import BCRSurfaceDomain
import BCRCoreMIDIDriver
import BCRTimingTestSupport
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class ReviewMIDI: MIDIService {
    let connection = MIDIConnectionSnapshot()
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sends = 0
    func start() throws {}
    func selectEndpoints(_ selection: MIDIEndpointSelection) {}
    func send(_ message: MIDIVoiceMessage) throws { sends += 1 }
}

@MainActor
final class InputReviewWorkspaceTests: XCTestCase {
    func testReviewSourceAndExportArePassiveAndKeepMappingsLearningValuesAndSendCount() async throws {
        let device = ReviewMIDI()
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false, midiService: device,
                                     automaticallyAdvancesMock: false, timing: .immediate)
        let review = model.inputReview
        let map = model.deviceWork.session.learnedHardwareMap, source = model.source,
            values = model.engine.parameterValues
        XCTAssertTrue(model.setWorkspacePanel(.inputReview, enabled: true))
        review.source = .mock
        XCTAssertEqual(review.review.observedControlCount, 0)
        review.source = .hardware
        XCTAssertEqual(review.review.observedControlCount, 0)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        review.export(to: root.appending(path: "review.json"))
        try await waitUntil("review export finishes") { !review.isExporting }
        XCTAssertNotNil(review.receipt)
        XCTAssertNil(review.error)
        XCTAssertEqual(device.sends, 0)
        XCTAssertEqual(model.deviceWork.session.learnedHardwareMap, map)
        XCTAssertEqual(model.source, source)
        XCTAssertEqual(model.engine.parameterValues, values)
        XCTAssertFalse(model.isLearning)
    }

    func testMockAndHardwareCoverageAreSeparatedAndFailedExportVisible() async throws {
        let device = ReviewMIDI()
        let model = ConsoleViewModel(stores: .temporary(), startsMIDI: false, midiService: device,
                                     automaticallyAdvancesMock: false, timing: .immediate)
        model.turn(.pushEncoder(group: 1, 1), by: 5)
        model.inputReview.source = .mock
        XCTAssertEqual(model.inputReview.review.observedControlCount, 1)
        model.inputReview.source = .hardware
        XCTAssertEqual(model.inputReview.review.observedControlCount, 0)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("protected".utf8).write(to: root)
        model.inputReview.export(to: root)
        try await waitUntil("export fails visibly") { !model.inputReview.isExporting }
        XCTAssertNotNil(model.inputReview.error)
        XCTAssertEqual(try Data(contentsOf: root), Data("protected".utf8))
        XCTAssertEqual(device.sends, 0)
    }
}
