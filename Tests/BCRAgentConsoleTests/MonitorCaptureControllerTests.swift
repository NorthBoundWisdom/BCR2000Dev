import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import BCRTestSupport
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
final class MonitorCaptureControllerTests: XCTestCase {
    func testCaptureStopsDurablyAndContextChangesRemainExplicit() async throws {
        let model = ConsoleViewModel(
            stores: .temporary(),
            startsMIDI: false,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
        let capture = model.monitorCapture
        capture.start()
        model.turn(.pushEncoder(group: 1, 1), by: 3)
        model.setAssignment(
            .init(control: .encoder(row: 1, 1), target: .parameter("general.1")),
            for: .encoder(row: 1, 1)
        )
        model.turn(.pushEncoder(group: 1, 1), by: 3)
        capture.stop()
        await capture.waitForWrites()
        XCTAssertEqual(capture.phase, .finished)
        let data = try Data(contentsOf: XCTUnwrap(capture.url))
        let rows = try data.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        XCTAssertTrue(rows.contains { $0.objectValue?["origin"] == .string("contextChanged") })
        let timestamps = rows.compactMap { $0.objectValue?["monotonicTimestamp"]?.finiteNumber }
        XCTAssertEqual(timestamps, timestamps.sorted())
        XCTAssertEqual(rows.last?.objectValue?["kind"], .string("capture-end"))
        let previous = data
        model.turn(.pushEncoder(group: 1, 1), by: 1)
        await capture.waitForWrites()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(capture.url)), previous)
    }

    func testCaptureFileFailureIsVisibleAndDoesNotBlockSessionValues() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocked".utf8).write(to: root)
        let model = ConsoleViewModel(
            stores: .temporary(),
            startsMIDI: false,
            automaticallyAdvancesMock: false,
            timing: .immediate
        )
        let capture = MonitorCaptureController(session: model.deviceWork.session,
                                               directory: root.appending(path: "Captures"))
        capture.start()
        model.setParameter("general.1", to: 72)
        await capture.waitForWrites()
        XCTAssertEqual(capture.phase, .failed)
        XCTAssertNotNil(capture.error)
        XCTAssertEqual(model.engine.value(of: "general.1"), 72)
    }
}
