import BCRSurfaceDomain
import BCRTestSupport
import Foundation
import XCTest

final class BCRPresetInspectionTests: XCTestCase {
    // Synthetic BCL illustrating the protocol variants found in third-party presets.
    private let lines = [
        "; A comment", "$rev R1", "$global", ".rxch off", "$preset",
        ".name 'Private; preset name' ; comment", ".egroups 3", ".tx $B0 $10 $00",
        "$encoder 1", ".easypar NRPN 1 164 0 127 absolute",
        "$encoder 2", ".easypar NRPN 1 164 0 16383 absolute/14",
        "$encoder 3", ".easypar CC 1 31 0 16383 relative-1/14",
        "$encoder 4", ".easypar CC 1 32 0 127 relative-2/14",
        "$encoder 5", ".easypar CC 1 40 0 127 relative-3",
        "$encoder 6", ".easypar NRPN 1 200 0 127 inc/dec",
        "$encoder 7", ".minmax -31 31", ".tx $F0 $7D val $F7",
        "$button 59", ".easypar CC 1 31 127 0 toggleoff",
        "$button 60", ".easypar PC 1 off off",
        "$store $1F", "$preset", "$encoder 1", ".easypar NRPN 1 164 0 127 absolute", "$store 32", "$recall 31", "$end"
    ]

    func testInventoriesWireModesAndBlockLocalDuplicates() throws {
        let report = try BCRPresetInspection.inspect(Data(lines.joined(separator: "\r\n").utf8), format: .text)
        XCTAssertEqual(report.presets.count, 2)
        let preset = try XCTUnwrap(report.presets.first)
        XCTAssertEqual(preset.encoderGroups, 3)
        XCTAssertEqual(preset.learnOutputLines, [8])
        XCTAssertEqual(preset.elements.compactMap { $0.bindings.first?.mode },
                       [
                           "absolute",
                           "absolute/14",
                           "relative-1/14",
                           "relative-2/14",
                           "relative-3",
                           "inc/dec",
                           "toggleoff"
                       ])
        XCTAssertEqual(preset.elements.prefix(6).map { $0.bindings.first?.dataBits }, [7, 14, 14, 7, 7, nil])
        XCTAssertEqual(preset.elements[6].minMax, [-31, 31])
        XCTAssertEqual(preset.elements[6].customOutputLines, [23])
        XCTAssertEqual(preset.elements[8].unsupportedEasyparLines, [27])
        XCTAssertEqual(preset.duplicateAddresses.map { $0.map(\.line) }, [[10, 12], [14, 25]])
        XCTAssertTrue(report.presets[1].duplicateAddresses.isEmpty)
        XCTAssertEqual(report.directives.map(\.kind), [.global, .store, .store, .recall])
        XCTAssertEqual(report.directives.map(\.slot), [nil, 31, 32, 31])
    }

    func testBCLAndBroadcastSysExHaveIdenticalInventoriesWithoutPrivateSourceText() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = try BCRPresetInspection.inspect(Data(lines.joined(separator: "\n").utf8), format: .text)
        let bytes = BCLFixtures.dump(lines, device: 0x7F)
        let syx = try BCRPresetInspection.inspect(bytes, format: .sysEx)
        let report = try encoder.encode(text)
        XCTAssertEqual(report, try encoder.encode(syx))
        XCTAssertFalse(String(decoding: report, as: UTF8.self).contains("Private"))
        XCTAssertFalse(String(decoding: report, as: UTF8.self).contains("$F0"))
        XCTAssertThrowsError(try BCRPresetEncoderLearning.prepare(
            dump: bytes, snapshot: [:], existingMap: HardwareMap(), configuration: .neutral()
        ))
    }

    func testRejectsTruncatedTextAndOutOfSequenceNonBCLSysEx() throws {
        XCTAssertThrowsError(try BCRPresetInspection.inspect(Data("$rev R1\n$preset".utf8), format: .text))
        XCTAssertThrowsError(try BCRPresetInspection.inspect(Data("$rev F1\n$preset\n$end".utf8), format: .text))
        var bytes = BCLFixtures.dump(["$rev R1", "$preset", "$end"])
        bytes[8] = 1
        XCTAssertThrowsError(try BCRPresetInspection.inspect(bytes, format: .sysEx))
        bytes[8] = 0
        bytes[6] = 0x34
        XCTAssertThrowsError(try BCRPresetInspection.inspect(bytes, format: .sysEx))
    }

    func testWrappedArchiveKeepsAbsoluteLineNumbersAndRejectsIncorrectWireIndex() throws {
        let prefix = ["$rev R1", "$global"] + Array(repeating: ".rxch off", count: 0x4000 - 2)
        let bytes = BCLFixtures.dump(prefix + [".deadtime 20", "$preset", ".egroups 4", "$end"])
        let report = try BCRPresetInspection.inspect(bytes, format: .sysEx)
        XCTAssertEqual(report.sysExIndexWrapLines, [0x4001])
        XCTAssertEqual(report.globalTimingSettings?.first?.line, 0x4001)
        XCTAssertEqual(report.presets.first?.line, 0x4002)
        XCTAssertThrowsError(try BCRPresetButtonLearning.prepare(dump: bytes, existingMap: HardwareMap()))

        var invalid = bytes
        invalid[BCLFixtures.dump(prefix).count + 8] = 1
        XCTAssertThrowsError(try BCRPresetInspection.inspect(invalid, format: .sysEx))
    }

    func testGlobalTimingReportsMissingAndInvalidSettingsWithoutDefaultingValues() throws {
        let text = [
            "$rev R1", "$global", ".deadtime 0", ".txinterval 5", "$preset",
            ".deadtime 100", "$global", ".deadtime 1001", ".txinterval 3",
            ".deadtime malformed", "$end"
        ].joined(separator: "\n")
        let report = try BCRPresetInspection.inspect(Data(text.utf8), format: .text)
        let settings = try XCTUnwrap(report.globalTimingSettings)
        XCTAssertEqual(settings.map(\.kind), [.deadTime, .transmitInterval, .deadTime, .transmitInterval, .deadTime])
        XCTAssertEqual(settings.map(\.line), [3, 4, 8, 9, 10])
        XCTAssertEqual(settings.map(\.milliseconds), [0, 5, 1001, 3, nil])
        XCTAssertEqual(settings.map(\.valid), [true, true, false, false, false])
        XCTAssertNil(report.sysExIndexWrapLines)
        let bare = try BCRPresetInspection.inspect(BCLFixtures.dump(["$rev R1", "$preset", "$end"]), format: .sysEx)
        XCTAssertNil(bare.globalTimingSettings)
        XCTAssertNil(bare.sysExIndexWrapLines)
    }

    func testInventoriesNoteVelocityAndButtonsWithNoReleaseValue() throws {
        let preset = BCLFixtures.dump([
            "$rev R1", "$preset", "$button 1", ".easypar NOTE 2 64 100 toggleoff",
            "$button 2", ".easypar NRPN 2 64 127 off toggleoff",
            "$button 3", ".easypar CC 2 64 127 0 increment -2", "$end"
        ])
        let report = try BCRPresetInspection.inspect(preset, format: .sysEx)
        let profile = try XCTUnwrap(report.presets.first)
        let bindings = profile.elements.flatMap(\.bindings)
        XCTAssertEqual(bindings.map(\.dataBits), [7, 7, 7])
        XCTAssertEqual(bindings.map(\.value2), [100, nil, 0])
        XCTAssertEqual(bindings.map(\.incrementStep), [nil, nil, -2])
        XCTAssertTrue(profile.duplicateAddresses.isEmpty, "Identical numbers in different MIDI message families")
    }
}
