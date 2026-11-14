import BCRConfigurationAdapter
import BCRFoundation
import BCRSurfaceDomain
import XCTest

final class HardwareRoleReadinessTests: XCTestCase {
    private func fixture(visualizationOnly: Bool = false,
                         mode: HardwarePressMode? = .momentary) -> (
        HardwareMap,
        SurfaceConfiguration,
        HardwareRoleReadiness.Request
    ) {
        let entries = [
            HardwareMapEntry(
                control: .button(row: 1, 1),
                midi: .init(kind: .controlChange, channel: 0, number: 1),
                visualizationOnly: visualizationOnly,
                pressMode: mode
            ),
            HardwareMapEntry(
                control: .button(row: 1, 2),
                midi: .init(kind: .controlChange, channel: 0, number: 2),
                visualizationOnly: visualizationOnly,
                pressMode: mode
            ),
            HardwareMapEntry(
                control: .pushEncoder(group: 1, 1),
                midi: .init(kind: .controlChange, channel: 0, number: 3)
            ),
            HardwareMapEntry(
                control: .pushEncoder(group: 1, 2),
                midi: .init(kind: .controlChange, channel: 0, number: 4)
            )
        ]
        return (HardwareMap(entries: entries), .init(name: "Test only", parameters: [], assignments: []),
                .init(roles: [
                    "enable": "button.1.1",
                    "stop": "button.1.2",
                    "linear": "pushEncoder.1.1",
                    "steer": "pushEncoder.1.2"
                ]))
    }

    func testVisualizationOnlyButtonsNeverBecomeAvailableRoles() throws {
        let (map, configuration, request) = fixture(visualizationOnly: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(map)
        let report = try HardwareRoleReadiness.check(map: map, configuration: configuration, request: request,
                                                     hardwareOutput: .write, displayPermission: true)
        XCTAssertFalse(report.ready)
        XCTAssertEqual(report.available_input_ids.count, 2)
        XCTAssertTrue(report.available_momentary_button_ids.isEmpty)
        XCTAssertTrue(report.available_indicator_feedback_ids.isEmpty)
        XCTAssertEqual(report.roles["enable"]?.input_ready, false)
        XCTAssertTrue(report.missing.contains("enable:accepted_input_required"))
        XCTAssertTrue(report.missing.contains("stop:visualization_only_input_is_ignored"))
        XCTAssertEqual(try encoder.encode(map), before)
        XCTAssertFalse(report.hardware_qualified)
    }

    func testMomentaryEdgesAndBothDisplayPermissionsRequired() throws {
        let (map, configuration, request) = fixture()
        for policy in [HardwareOutputPolicy.observe, .write] {
            for permission in [false, true] {
                let report = try HardwareRoleReadiness.check(map: map, configuration: configuration, request: request,
                                                             hardwareOutput: policy, displayPermission: permission)
                XCTAssertEqual(report.ready, policy == .write && permission)
                XCTAssertEqual(report.roles["enable"]?.input_ready, true)
            }
        }
        for mode in [HardwarePressMode?.none, .some(.pulse)] {
            let (map, configuration, request) = fixture(mode: mode)
            let report = try HardwareRoleReadiness.check(map: map, configuration: configuration, request: request,
                                                         hardwareOutput: .write, displayPermission: true)
            XCTAssertFalse(report.ready)
            XCTAssertTrue(report.missing.contains("enable:momentary_button_required"))
        }
    }

    func testMissingDuplicateAndWrongControlKindsFailClosed() throws {
        let (map, configuration, _) = fixture()
        for roles in [
            ["enable": "button.1.1"],
            ["enable": "button.1.1", "stop": "button.1.1", "linear": "pushEncoder.1.1", "steer": "pushEncoder.1.2"],
            ["enable": "pushEncoder.1.1", "stop": "button.1.2", "linear": "button.1.1", "steer": "pushEncoder.1.2"],
            ["enable": "missing", "stop": "button.1.2", "linear": "pushEncoder.1.1", "steer": "pushEncoder.1.2"]
        ] {
            let report = try HardwareRoleReadiness.check(map: map, configuration: configuration,
                                                         request: .init(roles: roles), hardwareOutput: .write,
                                                         displayPermission: true)
            XCTAssertFalse(report.ready)
            XCTAssertFalse(report.missing.isEmpty)
        }
    }

    func testReadOnlyCommandReportsBlockedAndInvalidInputs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mapURL = directory.appendingPathComponent("test-only-map.json")
        let configurationURL = directory.appendingPathComponent("test-only-config.json")
        let requestURL = directory.appendingPathComponent("test-only-request.json")
        let (map, configuration, request) = fixture(visualizationOnly: true)
        let original = try JSONEncoder().encode(map)
        try original.write(to: mapURL)
        try JSONEncoder().encode(configuration).write(to: configurationURL)
        try JSONEncoder().encode(request).write(to: requestURL)
        let args = [mapURL.path, requestURL.path, "--configuration", configurationURL.path,
                    "--hardware-output", "write", "--allow-surface-feedback"]
        let blocked = HardwareRoleReadiness.command(arguments: args)
        XCTAssertEqual(blocked.exitCode, 3)
        let report = try JSONSerialization.jsonObject(with: Data(blocked.output.utf8)) as! [String: Any]
        XCTAssertEqual(report["ready"] as? Bool, false)
        XCTAssertEqual(report["available_momentary_button_ids"] as? [String], [])
        XCTAssertEqual(try Data(contentsOf: mapURL), original)
        let invalid = HardwareRoleReadiness.command(arguments: args + ["--unknown"])
        XCTAssertEqual(invalid.exitCode, 2)
        XCTAssertTrue(invalid.output.contains("invalid_readiness_input"))
    }
}
