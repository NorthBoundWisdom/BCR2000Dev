import XCTest
@testable import BCRAgentCore
@testable import BCRCoreMIDIDriver

final class MIDIStartupProgramTests: XCTestCase {
    private let settings = [".name 'Robot'", ".snapshot off", ".request off", ".egroups 4", ".fkeys off", ".lock on"]

    func testFramesAreTemporaryBCLWithoutStore() throws {
        let program = try MIDIStartupProgram(preset: 3, presetSettings: settings)
        XCTAssertEqual(program.selectBytes, [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x22, 2, 0xF7])
        let frames = try program.frames()
        let lines = frames.map { String(decoding: $0.dropFirst(9).dropLast(), as: UTF8.self) }
        XCTAssertEqual(lines.first, "$rev R1")
        XCTAssertEqual(lines[1], "$preset")
        XCTAssertEqual(lines.last, "$end")
        XCTAssertFalse(lines.contains { $0.hasPrefix("$store") })
        // Group selection is reset by switching to one group and back.
        let egroups = lines.firstIndex(of: ".egroups 1")
        XCTAssertNotNil(egroups)
        XCTAssertEqual(lines[egroups! + 1], ".egroups 4")
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(Array(frame.prefix(7)), [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x20])
            XCTAssertEqual(Int(frame[7]) * 128 + Int(frame[8]), index)
            XCTAssertEqual(frame.last, 0xF7)
            XCTAssertTrue(frame.dropFirst().dropLast().allSatisfy { $0 < 0x80 })
        }
    }

    func testRejectsUnknownOrUnsafeSettings() {
        XCTAssertThrowsError(try MIDIStartupProgram(preset: 0, presetSettings: settings))
        XCTAssertThrowsError(try MIDIStartupProgram(preset: 33, presetSettings: settings))
        var store = settings; store[5] = "$store 1"
        XCTAssertThrowsError(try MIDIStartupProgram(preset: 1, presetSettings: store))
        var quote = settings; quote[0] = ".name 'a'b'"
        XCTAssertThrowsError(try MIDIStartupProgram(preset: 1, presetSettings: quote))
        var long = settings; long[0] = ".name '" + String(repeating: "x", count: 25) + "'"
        XCTAssertThrowsError(try MIDIStartupProgram(preset: 1, presetSettings: long))
        XCTAssertThrowsError(try MIDIStartupProgram(preset: 1, presetSettings: Array(settings.dropLast())))
        let json = Data(#"{"version":2,"preset":1,"presetSettings":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MIDIStartupProgram.self, from: json))
    }

    func testSysExAssemblerJoinsUMPChunksPerGroup() {
        // F0 00 20 32 7F 15 21 00 02 00 F7 (ACK for line 2, code 0) split as start/end 7-bit chunks.
        let start = MIDISysEx7Chunk(word0: 0x3016_0020, word1: 0x327F_1521)
        let end = MIDISysEx7Chunk(word0: 0x3033_0002, word1: 0x0000_0000)
        XCTAssertNotNil(start); XCTAssertNotNil(end)
        var assembler = MIDISysEx7Assembler()
        XCTAssertNil(assembler.consume(start!))
        XCTAssertEqual(assembler.consume(end!), [0xF0, 0, 0x20, 0x32, 0x7F, 0x15, 0x21, 0, 2, 0, 0xF7])
        // A continuation without a start is dropped instead of producing a partial frame.
        XCTAssertNil(assembler.consume(end!))
        // Non-SysEx UMP words are not chunks.
        XCTAssertNil(MIDISysEx7Chunk(word0: 0x20B0_0740, word1: 0))
    }
}
