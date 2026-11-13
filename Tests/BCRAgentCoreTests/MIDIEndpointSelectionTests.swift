import Foundation
import XCTest
@testable import BCRAgentCore
@testable import BCRMCPAdapter
@testable import BCRSurfaceDomain

final class MIDIEndpointSelectionTests: XCTestCase {
    private let endpoints = [
        MIDIEndpointDescriptor(id: 2, name: "BCR2000 Port 2"),
        .init(id: 1, name: "BCR2000 Port 1")
    ]
    func testDefaultPrefersPortOneAndExplicitChoiceUsesStableIdentity() throws {
        XCTAssertEqual(try MIDIEndpointPolicy.resolve(endpoints, selectedID: nil).id, 1)
        XCTAssertEqual(try MIDIEndpointPolicy.resolve(endpoints, selectedID: 2).id, 2)
        let renamed = [MIDIEndpointDescriptor(id: 2, name: "Renamed device")]
        XCTAssertEqual(try MIDIEndpointPolicy.resolve(renamed, selectedID: 2).id, 2)
    }

    func testMissingSelectionNeverFallsBackAndAbsentPortOneIsVisible() {
        XCTAssertThrowsError(try MIDIEndpointPolicy.resolve(endpoints, selectedID: 99))
        XCTAssertThrowsError(try MIDIEndpointPolicy.resolve(Array(endpoints.prefix(1)), selectedID: nil))
        XCTAssertThrowsError(try MIDIEndpointPolicy.resolve([], selectedID: nil))
    }

    func testSingleUnnumberedBCR2000EndpointIsAutomaticWithoutPortOne() throws {
        // ethanmacair (2026-11-14) lists one input and one output, each named just "BCR2000".
        XCTAssertEqual(try MIDIEndpointPolicy.resolve([.init(id: 7, name: "BCR2000")], selectedID: nil).id, 7)
        let withInterface = [MIDIEndpointDescriptor(id: 3, name: "USB MIDI Interface"), .init(id: 7, name: "BCR2000")]
        XCTAssertEqual(try MIDIEndpointPolicy.resolve(withInterface, selectedID: nil).id, 7)
        // Port 1 still wins, and anything ambiguous or numbered stays a visible error.
        XCTAssertEqual(
            try MIDIEndpointPolicy.resolve(endpoints + [.init(id: 7, name: "BCR2000")], selectedID: nil).id,
            1
        )
        XCTAssertThrowsError(try MIDIEndpointPolicy.resolve([.init(id: 2, name: "BCR2000 Port 2")], selectedID: nil))
        XCTAssertThrowsError(try MIDIEndpointPolicy.resolve(
            [.init(id: 7, name: "BCR2000"), .init(id: 8, name: "BCR2000 (2)")], selectedID: nil
        ))
        XCTAssertThrowsError(try MIDIEndpointPolicy.resolve(
            [.init(id: 7, name: "BCR2000"), .init(id: 2, name: "BCR2000 Port 2")], selectedID: nil
        ))
    }

    func testGenericInterfaceRequiresExplicitChoiceAndCannotCaptureAutoMode() throws {
        let interfaces = [MIDIEndpointDescriptor(id: 3, name: "USB MIDI Interface Port 1")] + endpoints
        XCTAssertEqual(try MIDIEndpointPolicy.resolve(interfaces, selectedID: nil).id, 1)
        XCTAssertEqual(try MIDIEndpointPolicy.resolve(interfaces, selectedID: 3).id, 3)
        XCTAssertThrowsError(try MIDIEndpointPolicy.resolve(Array(interfaces.prefix(1)), selectedID: nil))
    }

    func testSelectionsRoundTripAndRejectInvalidSettings() throws {
        let selection = MIDIEndpointSelection(sourceID: -12, destinationID: 9)
        let data = try JSONEncoder().encode(selection)
        XCTAssertEqual(try JSONDecoder().decode(MIDIEndpointSelection.self, from: data), selection)
        try selection.validate()
        XCTAssertThrowsError(try MIDIEndpointSelection(sourceID: 0).validate())
        var unsupported = selection; unsupported.version = 2
        XCTAssertThrowsError(try unsupported.validate())
    }
}
