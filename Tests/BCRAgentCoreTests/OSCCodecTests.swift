import Foundation
import XCTest
@testable import BCRAgentCore

final class OSCCodecTests: XCTestCase {
    func testFloatMessageMatchesBigEndianAlignedWireBytes() throws {
        let packet = OSCPacket.message(OSCMessage("/x", [.float(1)]))
        let data = try OSCCodec.encode(packet)
        XCTAssertEqual(Array(data), [47, 120, 0, 0, 44, 102, 0, 0, 63, 128, 0, 0])
        XCTAssertEqual(try OSCCodec.decode(data), packet)
    }

    func testIntegerStringAndNestedBundleRoundTrip() throws {
        let packet = OSCPacket.bundle(timetag: 1, elements: [
            .message(OSCMessage("/heartbeat", [.int(-1)])),
            .bundle(timetag: 1, elements: [.message(OSCMessage("/value", [.float(-3.5), .string("text")]))]),
        ])
        XCTAssertEqual(try OSCCodec.decode(OSCCodec.encode(packet)), packet)
        XCTAssertEqual(try OSCCodec.immediateMessages(packet).count, 2)
        XCTAssertThrowsError(try OSCCodec.immediateMessages(.bundle(timetag: 2, elements: [])))
    }

    func testParameterIDsUseAnUnambiguousASCIIPathComponent() throws {
        for id in ["arm.j1", "custom /含空格%"] {
            let encoded = OSCCodec.parameterAddress(ParameterID(id), prefix: "/bcr/state/")
            XCTAssertTrue(encoded.utf8.allSatisfy { $0 < 128 })
            XCTAssertEqual(try OSCCodec.parameterID(encoded), ParameterID(id))
        }
        XCTAssertThrowsError(try OSCCodec.parameterID("/other/x"))
        XCTAssertThrowsError(try OSCCodec.parameterID("/bcr/state/%ZZ"))
    }

    func testMalformedPaddingTruncationTypesAndNonfiniteNumbersAreRejected() throws {
        let good = try OSCCodec.encode(.message(OSCMessage("/x", [.float(1)])))
        XCTAssertThrowsError(try OSCCodec.decode(good.dropLast()))
        var badPadding = good
        badPadding[3] = 1
        XCTAssertThrowsError(try OSCCodec.decode(badPadding))
        var badType = good
        badType[5] = 113
        XCTAssertThrowsError(try OSCCodec.decode(badType))
        var nan = good
        nan.replaceSubrange(8..<12, with: [0x7f, 0xc0, 0, 0])
        XCTAssertThrowsError(try OSCCodec.decode(nan))
        XCTAssertThrowsError(try OSCCodec.encode(.message(OSCMessage("/x", [.float(.infinity)]))))
        XCTAssertThrowsError(try OSCCodec.encode(.message(OSCMessage("invalid", []))))
        XCTAssertThrowsError(try OSCCodec.encode(.message(OSCMessage("/x", [.string("bad\u{0}text")]))))
        XCTAssertThrowsError(try OSCCodec.decode(Data(repeating: 0, count: 4)))
    }

    func testBundleLengthAndNestingAreBounded() throws {
        var packet = OSCPacket.message(OSCMessage("/x", [.int(1)]))
        for _ in 0..<10 { packet = .bundle(timetag: 1, elements: [packet]) }
        XCTAssertThrowsError(try OSCCodec.encode(packet))
        var encoded = try OSCCodec.encode(.bundle(timetag: 1, elements: [.message(OSCMessage("/x", [.int(1)]))]))
        encoded.replaceSubrange(16..<20, with: [0x7f, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try OSCCodec.decode(encoded))
    }

    func testActualLEDProjectionNeverChangesTargetAndToggleRemainsTargetOwned() throws {
        let control = BCRControlID.encoder(row: 1, 1)
        let toggle = BCRControlID.button(row: 2, 1)
        var engine = SurfaceEngine(hardwareMap: .mockPreset(), configuration: SurfaceConfiguration(
            name: "Projection", parameters: [
                .init(id: "x", name: "X", minimum: 0, maximum: 100, step: 10),
                .init(id: "enabled", name: "Enable", minimum: 0, maximum: 1, kind: .toggle),
            ], assignments: [.init(control: control, target: .parameter("x")), .init(control: toggle, target: .parameter("enabled"))]
        ))
        _ = engine.setParameter("x", to: 80)
        _ = engine.setParameter("enabled", to: 1)
        _ = try engine.setActualFeedback(["x": 15.1])
        _ = engine.setLEDFeedbackSource(.actual)
        XCTAssertEqual(engine.value(of: "x"), 80)
        XCTAssertEqual(engine.state(of: control).value, 19)
        XCTAssertEqual(engine.state(of: toggle).value, 127)
        _ = engine.setParameter("x", to: 90)
        XCTAssertEqual(engine.state(of: control).value, 19)
        engine.echoWindow = 0
        let midi = engine.hardwareMap.midi(for: control)!
        _ = engine.handleInput(.controlChange(channel: midi.channel, number: UInt8(midi.number), value: 100))
        XCTAssertEqual(engine.value(of: "x"), 80)
        XCTAssertEqual(engine.state(of: control).value, 19)
        _ = engine.setParameter("x", to: 90)
        _ = engine.setLEDFeedbackSource(.target)
        XCTAssertEqual(engine.state(of: control).value, 114)
        XCTAssertThrowsError(try engine.setActualFeedback(["missing": 0]))
        XCTAssertThrowsError(try engine.setActualFeedback(["x": .nan]))
    }
    func testActualReadoutDoesNotSnapOrHideOutOfRangeValues() {
        let definition = ParameterDefinition(id: "x", name: "X", unit: "°", minimum: -180, maximum: 180, step: 0.5)
        XCTAssertTrue(definition.formatted(90.5).contains("90.5"))
        XCTAssertTrue(definition.formatted(181.25, snap: false, minimumFractionDigits: 2).contains("181.25"))
        XCTAssertTrue(definition.formatted(.nan, snap: false).contains("无效"))
    }

}
