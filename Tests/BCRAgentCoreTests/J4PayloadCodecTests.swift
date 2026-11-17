import Foundation
import XCTest
import SurfaceDeviceConformance

final class J4PayloadCodecTests: XCTestCase {
    func testExactScalarEncodingAndStrictRawAdmission() throws {
        for token in [
            "-0",
            "-0.0",
            "0e-4000",
            "-0e-4000",
            "5e-324",
            "1e-309",
            "-0.004144001900805731",
            "1.7976931348623157e308",
            "true",
            "false",
            "null",
            #""18446744073709551615""#,
            #""e\u0301""#,
            #""\u00e9""#,
            #""控制台🚀""#
        ] {
            let raw =
                Data(
                    (#"{"schema_version":1,"owner":"scalar-proof","ordinal":"1","operation":"initialize","arguments":{"rate":{"kind":"unlimited"}},"context":{"value":"# +
                        token + "}}").utf8
                )
            let old = try SchedulerTraceCodec.encodeInput(SchedulerTraceCodec.decodeInput(raw))
            let new = try SchedulerTraceCodec.encodeInput(J4PayloadCodec.envelope(raw))
            XCTAssertEqual(new, old, token)
        }
        for invalid in [
            #"{"a":true,"a":1}"#,
            #"{"v":1e309}"#,
            #"{"v":1e-400}"#,
            #"{"v":2.4703282292062327e-324}"#,
            #"{"v":1,}"#,
            "{\"\u{e9}\":1,\"e\u{301}\":2}"
        ] {
            XCTAssertThrowsError(try J4PayloadCodec.payload(Data(invalid.utf8)))
        }
        XCTAssertThrowsError(try J4PayloadCodec.payload(Data([123, 34, 118, 34, 58, 34, 255, 34, 125])))
    }

    func testSmallPayloadRoundTripPreservesUTF8AndDoubleBits() throws {
        let raw = Data(#"{"v":[true,1,null,"unknown","e\u0301","\u00e9",-0,-0.004144001900805731]}"#.utf8)
        let old = try JSONDecoder().decode(ScenarioPayload.self, from: raw)
        let new = try J4PayloadCodec.payload(raw)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(new), try encoder.encode(old))
        guard case let .object(values) = new, case let .array(elements) = values["v"],
              case let .scalar(.number(zero)) = elements[6], case let .scalar(.number(decimal)) = elements[7],
              case let .scalar(.text(nfd)) = elements[4], case let .scalar(.text(nfc)) = elements[5]
        else {
            return XCTFail("Full scalar kinds were not preserved")
        }
        XCTAssertEqual(zero.bitPattern, 0x8000000000000000)
        XCTAssertEqual(decimal.bitPattern, 0xbf70f94d0a376351)
        XCTAssertEqual(Array(nfd.utf8), [0x65, 0xcc, 0x81])
        XCTAssertEqual(Array(nfc.utf8), [0xc3, 0xa9])
    }
}
