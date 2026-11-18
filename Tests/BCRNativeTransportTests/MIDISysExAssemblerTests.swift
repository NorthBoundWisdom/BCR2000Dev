import XCTest
@testable import BCRCoreMIDIDriver

final class MIDISysExAssemblerTests: XCTestCase {
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
