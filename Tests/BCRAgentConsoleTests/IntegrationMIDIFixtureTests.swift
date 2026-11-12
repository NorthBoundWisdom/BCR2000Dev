#if DEBUG
    import BCRAgentCore
    import Foundation
    import XCTest
    @testable import BCRAgentConsole

    @MainActor
    final class IntegrationMIDIFixtureTests: XCTestCase {
        func testReadOnlySetupAndExplicitPresetWriteStayInsideTheIsolatedFixture() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try IntegrationMIDIFixture(directory: directory)
            try fixture.start()
            XCTAssertEqual(fixture.hardwareMap.entries.count, 56)
            let names = try await fixture.readPresetNames()
            XCTAssertEqual(names.presetNumber, 8)
            let original = try await fixture.readCurrentPreset()
            let expected = Set(fixture.hardwareMap.entries.map(\.midi))
            let snapshot = try await fixture.readSnapshot(expected: expected)
            XCTAssertEqual(snapshot.count, expected.count)
            let url = directory.appending(path: "connection-fixture.json")
            func state() throws -> [String: Any] {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            }
            XCTAssertEqual(try state()["voiceWrites"] as? Int, 0)
            XCTAssertEqual(try state()["presetWrites"] as? Int, 0)
            let plan = try BCRPresetAlignment.prepare(dump: original, hardwareMap: fixture.hardwareMap,
                                                      configuration: .robotArmDemo())
            try await fixture.sendPresetFrames(plan.frames(device: 0)) { _ in }
            XCTAssertEqual(try state()["presetWrites"] as? Int, 1)
            XCTAssertEqual(try state()["matchesOriginal"] as? Bool, false)
            XCTAssertEqual(try state()["voiceWrites"] as? Int, 0)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
                $0 == "connection-fixture.json"
            })
        }
    }
#endif
