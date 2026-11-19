import XCTest
import BCRFoundation
@testable import BCRCoreMIDIDriver

final class MIDISysExAssemblerTests: XCTestCase {
    func testPresetWriteFailureExplainsDeviceRejectionWithoutIncludingPresetValues() {
        let frame = [UInt8](repeating: 0, count: 9) + Array(".name 'Private preset'".utf8) + [0xF7]
        let failure = BCLPresetWriteFailure(index: 128, frame: frame, cause: .rejected(11))
        XCTAssertEqual(
            L10n.text(failure.localizedMessage, language: .english),
            "The device rejected BCL line 129 (.name) with error 11 (argument out of range). Confirmed lines: 128."
        )
        XCTAssertEqual(
            L10n.text(failure.localizedMessage, language: .traditionalChinese),
            "裝置拒絕 BCL 第 129 行（.name），錯誤 11（參數值超出範圍），已確認 128 行"
        )
    }

    func testPresetWriteFailureDistinguishesTimeoutAndUnknownCodes() {
        let frame = [UInt8](repeating: 0, count: 9) + Array("$rev R1".utf8) + [0xF7]
        let timeout = BCLPresetWriteFailure(index: 0, frame: frame, cause: .noReply)
        XCTAssertEqual(L10n.text(timeout.localizedMessage, language: .english),
                       "No reply for BCL line 1 ($rev). Confirmed lines: 0.")
        let rejected = BCLPresetWriteFailure(index: 0, frame: frame, cause: .rejected(99))
        XCTAssertTrue(L10n.text(rejected.localizedMessage, language: .english).contains("error 99"))
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
