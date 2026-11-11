import Foundation
import XCTest
@testable import BCRAgentCore

final class SurfaceProgramsTests: XCTestCase {
    func testPageSwitchPreservesValuesChangesAssignmentsAndRoundTrips() throws {
        var config = SurfaceConfiguration.starter()
        let knob = BCRControlID.pushEncoder(group: 1, 1)
        try config.addPage(.init(id: "second", name: "Second", assignments: [
            .init(control: knob, target: .parameter("general.2")),
            .init(control: .button(row: 2, 1), target: .switchPage(SurfaceConfiguration.basePageID))
        ]))
        var engine = SurfaceEngine(hardwareMap: .mockPreset(), configuration: config)
        _ = engine.setParameter("general.1", to: 80)
        _ = engine.setParameter("general.2", to: 30)
        let effects = try engine.selectPage("second")
        XCTAssertTrue(effects.contains(.pageChanged))
        XCTAssertEqual(engine.value(of: "general.1"), 80)
        XCTAssertEqual(engine.configuration.assignment(for: knob)?.target, .parameter("general.2"))
        let restored = try JSONDecoder().decode(
            SurfaceConfiguration.self,
            from: JSONEncoder().encode(engine.configuration)
        )
        XCTAssertEqual(restored, engine.configuration)
        XCTAssertEqual(restored.activePageID, "second")
        _ = try engine.selectPage(SurfaceConfiguration.basePageID)
        XCTAssertEqual(engine.configuration.assignment(for: knob)?.target, .parameter("general.1"))
    }

    func testMacroOrderClampingSnappingAndSinglePressDebounce() throws {
        var config = SurfaceConfiguration.starter()
        try config.addMacro(.init(
            id: "sequence",
            name: "Sequence",
            actions: [.set("general.1", 20), .step("general.1", 5), .step("general.2", 500)]
        ))
        let button = BCRControlID.button(row: 2, 1)
        try config.assign(.init(control: button, target: .runMacro("sequence")))
        var engine = SurfaceEngine(hardwareMap: .mockPreset(), configuration: config)
        let now = Date(timeIntervalSince1970: 100)
        _ = engine.press(button, isDown: true, at: now)
        XCTAssertEqual(engine.value(of: "general.1"), 25)
        XCTAssertEqual(engine.value(of: "general.2"), 100)
        XCTAssertTrue(engine.press(button, isDown: true, at: now.addingTimeInterval(0.1)).isEmpty)
    }

    func testHiddenPagesAndMacrosAreValidatedAndParameterDeletionCascades() throws {
        var config = SurfaceConfiguration.starter()
        XCTAssertThrowsError(try config.addMacro(.init(name: "Invalid", actions: [.set("missing", 1)])))
        XCTAssertThrowsError(try config.addPage(.init(
            name: "Invalid",
            assignments: [.init(control: .button(row: 1, 1), target: .runMacro("missing"))]
        )))
        try config.addMacro(.init(id: "m", name: "Macro", actions: [.step("general.1", 1)]))
        try config.addPage(.init(
            id: "p",
            name: "Page",
            assignments: [.init(control: .button(row: 1, 1), target: .runMacro("m"))]
        ))
        config.removeParameter("general.1")
        XCTAssertTrue(config.macros.isEmpty)
        XCTAssertTrue(config.pages[0].assignments.isEmpty)
        try config.validate()
    }

    func testVersionFourMigrationPreservesBaseAssignments() throws {
        let config = SurfaceConfiguration.starter()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        json["version"] = 4
        json.removeValue(forKey: "pages"); json.removeValue(forKey: "macros")
        let decoded = try JSONDecoder().decode(
            SurfaceConfiguration.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        let migrated = try decoded.migrated()
        XCTAssertEqual(migrated.version, SurfaceConfiguration.currentVersion)
        XCTAssertEqual(migrated.assignments, config.assignments)
        XCTAssertTrue(migrated.pages.isEmpty)
    }
}
