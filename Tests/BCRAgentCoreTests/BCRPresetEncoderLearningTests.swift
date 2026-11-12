import XCTest
@testable import BCRAgentCore
@testable import BCRMCPAdapter
@testable import BCRSurfaceDomain

final class BCRPresetEncoderLearningTests: XCTestCase {
    private func lines() -> [String] {
        ["$rev R1", "$preset", ".name 'Test'", ".egroups 4"] + (1 ... 56).flatMap {
            ["$encoder \($0)", ".easypar CC 7 \(120 - $0) 0 127 absolute", ".mode 12dot", ".default 0"]
        } + ["$end"]
    }

    private func dump(_ lines: [String]) -> Data {
        Data(lines.enumerated().flatMap { index, line in
            [0xF0, 0, 0x20, 0x32, 0, 0x15, 0x20, UInt8(index >> 7), UInt8(index & 127)]
                + Array(line.utf8) + [0xF7]
        })
    }

    private var snapshot: [MIDIControlID: UInt8] {
        Dictionary(uniqueKeysWithValues: (1 ... 56).map {
            (MIDIControlID(kind: .controlChange, channel: 6, number: 120 - $0), UInt8($0))
        })
    }

    func testLearnsAllGroupsAndRowsFromActualDefinitionsPreservingAssignments() throws {
        var existing = HardwareMap(version: 4)
        try existing.bind(.pushEncoder(group: 1, 1), to: MIDIControlID(kind: .controlChange, channel: 6, number: 119))
        let configuration = SurfaceConfiguration.robotArmDemo()
        let plan = try BCRPresetEncoderLearning.prepare(
            dump: dump(lines()), snapshot: snapshot, existingMap: existing, configuration: configuration
        )
        XCTAssertEqual(plan.hardwareMap.boundCount, 56)
        XCTAssertEqual(plan.hardwareMap.version, HardwareMap.currentVersion)
        XCTAssertEqual(plan.configuration.parameters.count, 57)
        for assignment in configuration.assignments {
            XCTAssertEqual(plan.configuration.assignment(for: assignment.control), assignment)
        }
        for (index, control) in (BCRLayout.controls(in: .pushEncoder) + BCRLayout.controls(in: .encoder)).enumerated() {
            XCTAssertEqual(plan.hardwareMap.midi(for: control)?.number, UInt16(119 - index))
            XCTAssertNotNil(plan.configuration.assignment(for: control))
            XCTAssertEqual(plan.hardwareMap.ringMode(for: control), .twoDot)
        }
        let repeated = try BCRPresetEncoderLearning.prepare(
            dump: dump(lines()), snapshot: snapshot, existingMap: plan.hardwareMap, configuration: plan.configuration
        )
        XCTAssertEqual(repeated.hardwareMap, plan.hardwareMap)
        XCTAssertEqual(repeated.configuration, plan.configuration)
    }

    func testRejectsMissingSnapshotConflictsUnsupportedModesAndTruncatedDump() throws {
        let config = SurfaceConfiguration.robotArmDemo()
        let first = MIDIControlID(kind: .controlChange, channel: 6, number: 119)
        var missing = snapshot
        missing.removeValue(forKey: first)
        XCTAssertThrowsError(try BCRPresetEncoderLearning.prepare(
            dump: dump(lines()), snapshot: missing, existingMap: HardwareMap(), configuration: config
        ))
        var conflicting = HardwareMap()
        try conflicting.bind(.pushEncoder(group: 1, 1), to: MIDIControlID(kind: .controlChange, channel: 0, number: 1))
        XCTAssertThrowsError(try BCRPresetEncoderLearning.prepare(
            dump: dump(lines()), snapshot: snapshot, existingMap: conflicting, configuration: config
        ))
        let variants = [
            Array(lines().dropLast()),
            lines().map { $0.replacingOccurrences(of: "absolute", with: "relative-1") },
            lines().map { $0.replacingOccurrences(of: ".egroups 4", with: ".egroups 1") },
            lines().map { $0.replacingOccurrences(of: "$encoder 56", with: "$encoder 55") },
            lines().map { $0.replacingOccurrences(of: "CC 7 118", with: "CC 7 119") },
            lines().dropLast() + [".tx 176 1 2", "$end"],
            lines().dropLast() + ["$preset", "$end"]
        ]
        for invalid in variants {
            XCTAssertThrowsError(try BCRPresetEncoderLearning.prepare(
                dump: dump(invalid), snapshot: snapshot, existingMap: HardwareMap(), configuration: config
            ))
        }
        var broken = dump(lines())
        broken[8] = 1
        XCTAssertThrowsError(try BCRPresetEncoderLearning.prepare(
            dump: broken, snapshot: snapshot, existingMap: HardwareMap(), configuration: config
        ))
    }

    func testAllEncodersRouteInputAndSoftwareFeedbackThroughEngine() throws {
        let plan = try BCRPresetEncoderLearning.prepare(
            dump: dump(lines()), snapshot: snapshot, existingMap: HardwareMap(), configuration: .robotArmDemo()
        )
        var engine = SurfaceEngine(hardwareMap: plan.hardwareMap, configuration: plan.configuration)
        var mock = MockBCR2000(preset: plan.hardwareMap)
        let now = Date(timeIntervalSince1970: 100)
        for entry in plan.hardwareMap.entries {
            let input = try XCTUnwrap(mock.turn(entry.control, by: 100))
            _ = engine.handleInput(input, at: now)
            let id = try XCTUnwrap(plan.configuration.assignment(for: entry.control)?.target.parameterID)
            let definition = try XCTUnwrap(plan.configuration.parameter(id))
            XCTAssertEqual(engine.value(of: id), definition.value(fromMIDI: 100))
            let effects = engine.setParameter(id, to: definition.value(fromMIDI: 32), at: now.addingTimeInterval(1))
            for effect in effects {
                if case let .send(message) = effect { _ = mock.receive(message) }
            }
            XCTAssertEqual(mock.value(of: entry.control), 32, entry.control.shortName)
        }
    }
}
