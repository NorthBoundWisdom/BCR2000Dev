import BCRFoundation
import BCRSurfaceDomain
import BCRPersistenceAdapter
import BCRConfigurationAdapter
import Foundation
import XCTest

@MainActor
private final class SceneDevice: SurfaceDevice {
    var connection = MIDIConnectionSnapshot(connectedSource: "input", connectedDestination: "output")
    var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
    var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
    var messages: [MIDIVoiceMessage] = []
    func send(_ message: MIDIVoiceMessage) throws { messages.append(message) }
}

@MainActor
final class ParameterSceneTests: XCTestCase {
    private func configuration() -> SurfaceConfiguration {
        .init(name: "scene", parameters: [.init(id: "x", name: "X"), .init(id: "y", name: "Y")], assignments: [
            .init(control: .pushEncoder(group: 1, 1), target: .parameter("x")),
            .init(control: .pushEncoder(group: 1, 2), target: .parameter("y"))
        ])
    }

    private func session(_ device: SceneDevice = .init(),
                         configuration: SurfaceConfiguration? = nil) -> SurfaceSession
    {
        SurfaceSession(
            hardwareDevice: device,
            hardwareMap: .mockPreset(),
            configuration: configuration ?? self.configuration(),
            saveHardwareMap: { _ in },
            saveConfiguration: { _ in }
        )
    }

    func testSceneMetadataIsSilentAndOverwriteMustBeConfirmed() async throws {
        let device = SceneDevice(), s = session(device)
        s.selectSource(.hardware)
        s.setParameter("x", to: 20)
        let before = device.messages
        try s.captureScene(id: "s", name: "Intro")
        XCTAssertEqual(device.messages, before)
        s.setParameter("x", to: 40)
        XCTAssertThrowsError(try s.captureScene(id: "new", name: "Intro")) {
            XCTAssertEqual($0 as? ParameterSceneError, .overwriteRequiresConfirmation)
        }
        XCTAssertEqual(s.engine.configuration.scenes?.first?.values["x"], 20)
        try s.captureScene(id: "new", name: "Intro", overwrite: true)
        XCTAssertEqual(s.engine.configuration.scenes?.map(\.id), ["s"])
        XCTAssertEqual(s.engine.configuration.scenes?.first?.values["x"], 40)
        let count = device.messages.count, values = s.engine.parameterValues
        try s.renameScene("s", to: "  Verse  ")
        XCTAssertEqual(s.engine.configuration.scenes?.first?.name, "Verse")
        XCTAssertThrowsError(try s.renameScene("s", to: "  "))
        try s.deleteScene("s")
        XCTAssertEqual(s.engine.parameterValues, values)
        XCTAssertEqual(device.messages.count, count)
    }

    func testSceneRecallIsOneUndoableBatchAndRefreshesRings() async throws {
        let device = SceneDevice(), s = session(device)
        s.selectSource(.hardware)
        s.withParameterHistory { s.setParameter("x", to: 30); s.setParameter("y", to: 60) }
        try s.captureScene(id: "s", name: "Scene")
        s.withParameterHistory { s.setParameter("x", to: 5); s.setParameter("y", to: 10) }
        device.messages.removeAll()
        XCTAssertEqual(try s.recallScene("s").missingParameters, [])
        XCTAssertEqual(s.engine.value(of: "x"), 30); XCTAssertEqual(s.engine.value(of: "y"), 60)
        XCTAssertEqual(device.messages.count, 2)
        try s.undo()
        XCTAssertEqual(s.engine.value(of: "x"), 5); XCTAssertEqual(s.engine.value(of: "y"), 10)
        try s.redo()
        XCTAssertEqual(s.engine.value(of: "x"), 30); XCTAssertEqual(s.engine.value(of: "y"), 60)
    }

    func testDeletedParametersRemainInEvidenceAndRecallReportsThem() async throws {
        let s = session()
        s.setParameter("x", to: 45); s.setParameter("y", to: 80)
        try s.captureScene(id: "s", name: "Scene")
        s.removeParameter("y")
        s.setParameter("x", to: 0)
        XCTAssertEqual(try s.recallScene("s").missingParameters, ["y"])
        XCTAssertEqual(s.engine.value(of: "x"), 45)
        XCTAssertNil(s.engine.value(of: "y"))
        XCTAssertEqual(s.engine.configuration.scenes?.first?.values["y"], 80)
        try s.engine.configuration.validate()
    }

    func testOldProfileStaysReadableAndSceneJSONRoundTripsThroughStore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var legacy = configuration(); legacy.version = 7
        let store = JSONFileStore<SurfaceConfiguration>(fileURL: root.appending(path: "profile.json"))
        try store.save(legacy)
        let before = try Data(contentsOf: store.fileURL)
        let restored = try XCTUnwrap(store.load())
        XCTAssertNil(restored.scenes)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        let s = session(configuration: try restored.migrated())
        try s.captureScene(id: "id", name: "我的 Intro")
        try store.save(s.engine.configuration)
        let reopened = try XCTUnwrap(store.load())
        XCTAssertEqual(reopened.scenes, s.engine.configuration.scenes)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let scenes = try XCTUnwrap(raw["scenes"] as? [[String: Any]])
        XCTAssertEqual(Set(scenes[0].keys), ["id", "name", "values"])
        XCTAssertNotNil(scenes[0]["values"] as? [String: Double])
    }

    func testInvalidScenesAreRejectedIncludingDuplicateNamesAndNonFiniteValues() async throws {
        for scene in [ParameterScene(id: "", name: "S", values: [:]),
                      ParameterScene(id: "s", name: " ", values: [:]),
                      ParameterScene(id: "s", name: "S", values: ["x": .infinity]),
                      ParameterScene(id: "s", name: "S", values: ["": 1])]
        {
            var config = configuration()
            XCTAssertThrowsError(try config.setScenes([scene]))
            XCTAssertNil(config.scenes)
        }
        var config = configuration()
        XCTAssertThrowsError(try config.setScenes([.init(id: "a", name: "Same", values: [:]),
                                                   .init(id: "b", name: "Same", values: [:])]))
        let bad = Data("{\"id\":\"\",\"name\":\"Scene\",\"values\":{}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ParameterScene.self, from: bad))
    }

    func testRecallCannotChangeProtectedValuesAndIsAtomic() async throws {
        let s = session()
        s.withParameterHistory { s.setParameter("x", to: 20); s.setParameter("y", to: 40) }
        try s.captureScene(id: "s", name: "Scene")
        s.withParameterHistory { s.setParameter("x", to: 0); s.setParameter("y", to: 0) }
        var definition = try XCTUnwrap(s.engine.configuration.parameter("y"))
        definition.agentWritable = false
        try s.updateParameter(definition)
        let values = s.engine.parameterValues
        XCTAssertThrowsError(try s.recallScene("s"))
        XCTAssertEqual(s.engine.parameterValues, values)
    }
}
