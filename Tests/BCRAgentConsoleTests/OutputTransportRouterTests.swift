import BCRAgentCore
import Foundation
import XCTest
@testable import BCRAgentConsole

@MainActor
private final class RoutedFakeTransport: OutputTransport {
    var isConnected = false
    var onSamples: (@MainActor ([ParameterSample]) -> Void)?
    var onHeartbeat: (@MainActor (Date) -> Void)?
    var onConnection: (@MainActor (Bool, String?) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPeerReset: (@MainActor (Date) -> Void)?
    var onDroppedPacket: (@MainActor () -> Void)?
    var stops = 0
    var selected: OutputTransportKind?
    func select(_ kind: OutputTransportKind) throws { selected = kind }
    func start(host: String, port: UInt16) throws { isConnected = true }
    func ping(at now: Date) throws {}
    func send(_ frame: ParameterOutputFrame) throws {}
    func stop() { stops += 1; isConnected = false }
}

@MainActor
final class OutputTransportRouterTests: XCTestCase {
    func testSwitchStopsOldAdapterAndRejectsStaleCapturedCallbacks() throws {
        let osc = RoutedFakeTransport(), ws = RoutedFakeTransport()
        let router = OutputTransportRouter { $0 == .osc ? osc : ws }
        var errors: [String] = []
        router.onFailure = { errors.append($0) }
        let oldFailure = osc.onFailure
        try router.select(.webSocket)
        XCTAssertEqual(osc.stops, 1)
        XCTAssertNil(osc.onFailure)
        XCTAssertEqual(ws.selected, .webSocket)
        oldFailure?("stale")
        ws.onFailure?("current")
        XCTAssertEqual(errors, ["current"])
        router.stop()
        let stopped = ws.onFailure
        stopped?("late after stop")
        XCTAssertEqual(errors, ["current"])
        try router.start(host: "127.0.0.1", port: 9000)
        ws.onFailure?("restarted")
        XCTAssertEqual(errors, ["current", "restarted"])
    }
}
