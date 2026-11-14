import XCTest
@testable import BCRAgentCore

@MainActor
private final class StartupDevice: SurfaceDevice {
    var connection = MIDIConnectionSnapshot(connectedSource: "BCR2000 Port 1", connectedDestination: "BCR2000 Port 1")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var sent: [MIDIVoiceMessage] = []
    func send(_ message: MIDIVoiceMessage) throws { sent.append(message) }
}

@MainActor
final class HardwareStartupSnapshotTests: XCTestCase {
    private func fixture() throws -> (SurfaceSession, StartupDevice, [MIDIVoiceMessage]) {
        let device = StartupDevice()
        var map = HardwareMap()
        try map.bind(.pushEncoder(group: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 11))
        try map.bind(.pushEncoder(group: 4, 1), to: .init(kind: .controlChange, channel: 0, number: 12))
        try map.bind(.button(row: 1, 1), to: .init(kind: .controlChange, channel: 0, number: 13))
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: map, configuration: .robotArmDemo(),
                                     saveHardwareMap: { _ in }, saveConfiguration: { _ in })
        return (session, device, [
            .controlChange(channel: 0, number: 11, value: 77),
            .controlChange(channel: 0, number: 12, value: 3),
            .controlChange(channel: 0, number: 13, value: 127)
        ])
    }

    func testStartupAdoptsAbsoluteValuesAndSendsOnlyButtonLEDsWithoutActionsOrTouch() throws {
        let (session, device, snapshot) = try fixture()
        var actions = 0, touches = 0
        session.onTriggerAgent = { _ in actions += 1 }
        session.onEvent = { if case .touched = $0 { touches += 1 } }
        try session.adoptHardwareSnapshot(snapshot)
        XCTAssertEqual(session.source, .hardware)
        XCTAssertEqual(session.engine.state(of: .pushEncoder(group: 4, 1)).value, 3)
        XCTAssertEqual(
            session.engine.value(of: "arm.j1"),
            session.engine.configuration.parameter("arm.j1")?.value(fromMIDI: 77)
        )
        // Only the software-owned button LED is written; encoder values stay as read from the device.
        XCTAssertEqual(device.sent.map(\.controlID.number), [13])
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(touches, 0)
    }

    func testIncompleteAndConflictingSnapshotsAreAtomic() throws {
        for conflicting in [false, true] {
            let (session, device, snapshot) = try fixture()
            let before = session.engine.parameterValues
            let bad = conflicting ? snapshot + [.controlChange(channel: 0, number: 11, value: 78)] :
                Array(snapshot.prefix(1))
            XCTAssertThrowsError(try session.adoptHardwareSnapshot(bad))
            XCTAssertEqual(session.source, .mock)
            XCTAssertEqual(session.engine.parameterValues, before)
            XCTAssertTrue(device.sent.isEmpty)
        }
    }
}
