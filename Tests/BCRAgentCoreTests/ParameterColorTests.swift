import BCRFoundation
import BCRSurfaceDomain
import BCRConfigurationAdapter
@testable import BCRMCPAdapter
import Foundation
import XCTest

@MainActor
private final class ColorDevice: SurfaceDevice {
    var connection = MIDIConnectionSnapshot(connectedSource: "in", connectedDestination: "out")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var messages: [MIDIVoiceMessage] = []
    func send(_ message: MIDIVoiceMessage) throws { messages.append(message) }
}

@MainActor
final class ParameterColorTests: XCTestCase {
    func testAllColorsRoundTripAndOlderProfilesNeedNoColorField() async throws {
        XCTAssertEqual(
            ParameterColor.allCases.map(\.rawValue),
            ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]
        )
        for color in ParameterColor.allCases {
            let definition = ParameterDefinition(id: "x", name: "X", color: color)
            let data = try JSONEncoder().encode(definition)
            XCTAssertEqual(try JSONDecoder().decode(ParameterDefinition.self, from: data), definition)
        }
        let raw = Data("{\"id\":\"x\",\"name\":\"X\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(ParameterDefinition.self, from: raw).color)
        let invalid = Data("{\"id\":\"x\",\"name\":\"X\",\"color\":\"cyan\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ParameterDefinition.self, from: invalid))
    }

    func testMetadataAndHighlightSendNothingAndNeverEnterUndoHistory() async throws {
        let device = ColorDevice()
        var saves: [SurfaceConfiguration] = []
        let session = SurfaceSession(hardwareDevice: device, hardwareMap: .mockPreset(),
                                     configuration: .neutral(), saveHardwareMap: { _ in },
                                     saveConfiguration: { saves.append($0) })
        session.selectSource(.hardware)
        let before = device.messages, values = session.engine.parameterValues
        for color in ParameterColor.allCases { try session.setParameterColor(color, for: "general.1") }
        try session.highlightGroup(session.engine.configuration.parameters[0].group)
        try session.highlightGroup(nil)
        XCTAssertThrowsError(try session.highlightGroup("missing"))
        XCTAssertNil(session.highlightedGroup)
        XCTAssertEqual(device.messages, before)
        XCTAssertEqual(session.engine.parameterValues, values)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(saves.last?.parameter("general.1")?.color, .pink)
        let gateway = AgentControlService(session: session)
        XCTAssertNil(try gateway.parameterInfo("general.1").objectValue?["color"], "Provider 1.0 schema is unchanged")
        gateway.permissions.configurationWrite = true
        var definition = try XCTUnwrap(session.engine.configuration.parameter("general.1"))
        definition.color = nil
        definition.name = "Remote rename"
        let result = gateway.call("update_parameter", arguments: .object(["definition": try .encoded(definition)]))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(session.engine.configuration.parameter("general.1")?.color, .pink)
        try session.highlightGroup(session.engine.configuration.parameters[0].group)
        try session.replaceConfiguration(session.engine.configuration)
        XCTAssertNil(session.highlightedGroup)
    }
}
