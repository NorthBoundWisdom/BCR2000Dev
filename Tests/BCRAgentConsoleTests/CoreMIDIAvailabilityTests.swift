import CoreMIDI
import XCTest
@testable import BCRAgentConsole

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
