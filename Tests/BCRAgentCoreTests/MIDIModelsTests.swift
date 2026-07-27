import XCTest
@testable import BCRAgentCore

final class MIDIModelsTests: XCTestCase {
    func testControlChangeUMPEncodingMatchesMIDI10Layout() {
        let message = MIDIVoiceMessage.controlChange(
            channel: 0,
            number: 74,
            value: 127
        )

        let word = MIDI1UMPCodec.encode(message)

        XCTAssertEqual(word, 0x20B04A7F)
        XCTAssertEqual(MIDI1UMPCodec.decode(word: word), message)
    }

    func testNoteOnAndOffRoundTrip() {
        let messages: [MIDIVoiceMessage] = [
            .noteOn(channel: 2, number: 60, velocity: 100),
            .noteOff(channel: 2, number: 60, velocity: 12),
        ]

        for message in messages {
            XCTAssertEqual(
                MIDI1UMPCodec.decode(word: MIDI1UMPCodec.encode(message)),
                message
            )
        }
    }

    func testIgnoresUnsupportedUMPMessageTypes() {
        XCTAssertNil(MIDI1UMPCodec.decode(word: 0x40903C00))
        XCTAssertNil(MIDI1UMPCodec.decode(word: 0x20E00000))
    }

    func testStreamDecoderSkipsContinuationWords() {
        let sysExFirstWord: UInt32 = 0x30160102
        let continuationThatLooksLikeCC: UInt32 = 0x20B04A7F
        let realCC: UInt32 = 0x20B00740

        XCTAssertEqual(
            MIDI1UMPCodec.decode(
                words: [sysExFirstWord, continuationThatLooksLikeCC, realCC]
            ),
            [.controlChange(channel: 0, number: 7, value: 64)]
        )
    }

    func testStateFeedbackUsesSameLearnedControl() {
        let control = MIDIControlID(kind: .controlChange, channel: 3, number: 21)
        let message = MIDI1UMPCodec.feedback(
            control: control,
            value: AgentRunState.running.feedbackValue
        )

        XCTAssertEqual(
            message,
            .controlChange(channel: 3, number: 21, value: 127)
        )
    }
}
