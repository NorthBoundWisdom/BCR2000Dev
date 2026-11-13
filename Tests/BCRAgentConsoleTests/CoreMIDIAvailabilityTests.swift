import CoreMIDI
import XCTest
@testable import BCRAgentConsole
@testable import BCRCoreMIDIDriver
@testable import BCRHTTPTransport

final class CoreMIDIAvailabilityTests: XCTestCase {
    func testExplicitlyOfflineEndpointsAreExcluded() {
        XCTAssertTrue(CoreMIDIEndpointAvailability.isUsable(status: noErr, offline: 0))
        XCTAssertFalse(CoreMIDIEndpointAvailability.isUsable(status: noErr, offline: 1))
    }

    func testOptionalUnknownPropertyIsNotMisreportedAsOffline() {
        XCTAssertTrue(CoreMIDIEndpointAvailability.isUsable(status: kMIDIUnknownProperty, offline: 0))
        XCTAssertFalse(CoreMIDIEndpointAvailability.isUsable(status: -1, offline: 0))
    }
}

final class PresetDumpStreamTests: XCTestCase {
    private func frame(_ index: Int, _ line: String) -> [UInt8] {
        [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x20, UInt8(index / 128), UInt8(index % 128)]
            + Array(line.utf8) + [0xF7]
    }

    func testSuccessfulStreamRequiresOrderedLinesAndEnd() throws {
        var stream = PresetDumpStream()
        let first = frame(0, "$rev R1"), last = frame(1, "$end")
        XCTAssertNil(stream.receive(first))
        XCTAssertEqual(try XCTUnwrap(stream.receive(last)).get(), Data(first + last))
    }

    func testCancellationWaitsForTrailingLinesAndEndBeforeReleasingRoute() throws {
        var stream = PresetDumpStream()
        XCTAssertNil(stream.receive(frame(0, "$rev R1")))
        stream.fail(CancellationError())
        for index in 1 ... 553 { XCTAssertNil(stream.receive(frame(index, ".showvalue on"))) }
        let result = try XCTUnwrap(stream.receive(frame(554, "$end")))
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        // Only after the old end can the next request start with line zero.
        stream = PresetDumpStream()
        XCTAssertNil(stream.receive(frame(0, "$rev R1")))
        XCTAssertNoThrow(try XCTUnwrap(stream.receive(frame(1, "$end"))).get())
    }

    func testMalformedStreamAlsoDrainsInsteadOfReleasingOnTheBadLine() throws {
        var stream = PresetDumpStream()
        XCTAssertNil(stream.receive(frame(9, ".lock on")))
        XCTAssertNotNil(stream.failure)
        XCTAssertNil(stream.receive(frame(10, ".showvalue off")))
        XCTAssertThrowsError(try XCTUnwrap(stream.receive(frame(11, "$end"))).get())
    }
}
