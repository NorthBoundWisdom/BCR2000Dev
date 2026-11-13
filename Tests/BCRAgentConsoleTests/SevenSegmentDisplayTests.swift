import AppKit
import BCRSurfaceDomain
import SwiftUI
import XCTest
@testable import BCRAgentConsole

final class SevenSegmentDisplayTests: XCTestCase {
    func testEveryDecimalDigitHasTheStandardSevenSegmentEncoding() {
        let expected: [UInt8] = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]
        for (digit, mask) in expected.enumerated() {
            XCTAssertEqual(BCRSevenSegmentDisplay.masks(for: String(digit)), [0, 0, 0, mask])
        }
        XCTAssertEqual(BCRSevenSegmentDisplay.masks(for: "8888"), [0x7F, 0x7F, 0x7F, 0x7F])
    }

    func testPresetAndButtonCodesUseSegmentsRatherThanFontGlyphs() {
        XCTAssertEqual(BCRSevenSegmentDisplay.masks(for: "P- 1"), [0x73, 0x40, 0, 0x06])
        XCTAssertEqual(BCRSevenSegmentDisplay.masks(for: "P-32"), [0x73, 0x40, 0x4F, 0x5B])
        XCTAssertEqual(BCRSevenSegmentDisplay.masks(for: "  on"), [0, 0, 0x5C, 0x54])
        XCTAssertEqual(BCRSevenSegmentDisplay.masks(for: " oFF"), [0, 0x5C, 0x71, 0x71])
        XCTAssertEqual(BCRSevenSegmentDisplay.masks(for: "----"), [0x40, 0x40, 0x40, 0x40])
    }

    func testBusyFramesChaseTheSameTwelveOuterSegments() {
        let expected: [[UInt8]] = [
            [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1],
            [0, 0, 0, 2], [0, 0, 0, 4], [0, 0, 0, 8], [0, 0, 8, 0],
            [0, 8, 0, 0], [8, 0, 0, 0], [16, 0, 0, 0], [32, 0, 0, 0]
        ]
        for frame in 0 ..< 12 {
            XCTAssertEqual(BCRSevenSegmentDisplay.busyMasks(frame: frame), expected[frame])
        }
    }

    @MainActor
    func testVectorDisplayRendersAVisualReviewGallery() throws {
        let gallery = VStack(spacing: 8) {
            ForEach(
                Array([BCRDisplayModel.Content.preset(1), .preset(32), .value(8888), .on, .off, .unknown].enumerated()),
                id: \.offset
            ) { _, content in
                LEDDisplay(content: content)
            }
        }
        .padding(12)
        .background(Color(red: 0.08, green: 0.09, blue: 0.10))
        let renderer = ImageRenderer(content: gallery)
        renderer.scale = 5
        let rendered = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        let destination = FileManager.default.temporaryDirectory.appending(path: "BCR-seven-segment-review.png")
        try png.write(to: destination, options: .atomic)
        print("LED_REVIEW_IMAGE=\(destination.path)")
    }
}
