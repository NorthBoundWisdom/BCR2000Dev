import BCRFoundation
import BCRSurfaceDomain
import SwiftUI

/// Code-driven four-digit display. Text is retained only as the logical/a11y value;
/// every visible glyph and transfer frame is drawn from the same 28 segment paths.
struct LEDDisplay: View {
    let text: String
    var busy = false
    var operation: BCRDisplayModel.TransferOperation = .read
    @Environment(\.panelMetrics) private var m

    var body: some View {
        Group {
            if busy {
                TimelineView(.periodic(
                    from: .now,
                    by: 1 / BCRDisplayModel.Calibration.framesPerSecond(for: operation)
                )) { context in
                    SevenSegmentCells(masks: BCRSevenSegmentDisplay.busyMasks(frame: BCRDisplayModel.busyFrame(
                        at: context.date.timeIntervalSinceReferenceDate, operation: operation
                    )))
                }
            } else {
                SevenSegmentCells(masks: BCRSevenSegmentDisplay.masks(for: text))
            }
        }
        .frame(width: m(60), height: m(22))
        .frame(width: m(78), height: m(30))
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: m(4)))
        .overlay { RoundedRectangle(cornerRadius: m(4)).stroke(Color.white.opacity(0.1)) }
        // Keep the whole bezel hoverable for the help attached by the surface view.
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("surface.led")
        .accessibilityLabel(L10n.text("LED 显示"))
        .accessibilityValue(busy
            ? (operation == .write ? L10n.text("设备正在写入预设") : L10n.text("设备正在读取预设")) : text)
    }
}

private struct SevenSegmentCells: View {
    let masks: [UInt8]

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 60, size.height / 22)
            let origin = CGPoint(x: (size.width - 60 * scale) / 2, y: (size.height - 22 * scale) / 2)
            var unlit = Path(), lit = Path()
            for digit in 0 ..< 4 {
                for segment in 0 ..< 7 {
                    let points = Self.points(for: segment).map { point in
                        CGPoint(x: origin.x + (CGFloat(digit) * 16 + point.x) * scale,
                                y: origin.y + point.y * scale)
                    }
                    let path = Path { path in
                        path.addLines(points)
                        path.closeSubpath()
                    }
                    unlit.addPath(path)
                    if masks[digit] & (1 << segment) != 0 { lit.addPath(path) }
                }
            }
            // The unpowered cells retain a faint physical "8888" silhouette.
            context.fill(unlit, with: .color(Theme.led.opacity(0.065)))
            var illuminated = context
            illuminated.addFilter(.shadow(color: Theme.led.opacity(0.7), radius: 1.5 * scale))
            illuminated.fill(lit, with: .color(Theme.led))
        }
        .accessibilityHidden(true)
    }

    /// Bevelled bars with black gaps, in one 12 × 22 digit cell.
    private static func points(for segment: Int) -> [CGPoint] {
        let box: CGRect
        let horizontal: Bool
        switch segment {
        case 0: box = CGRect(x: 1.3, y: 0.8, width: 9.4, height: 2); horizontal = true
        case 1: box = CGRect(x: 9.7, y: 2.5, width: 2, height: 7.8); horizontal = false
        case 2: box = CGRect(x: 9.7, y: 11.7, width: 2, height: 7.8); horizontal = false
        case 3: box = CGRect(x: 1.3, y: 19.2, width: 9.4, height: 2); horizontal = true
        case 4: box = CGRect(x: 0.3, y: 11.7, width: 2, height: 7.8); horizontal = false
        case 5: box = CGRect(x: 0.3, y: 2.5, width: 2, height: 7.8); horizontal = false
        default: box = CGRect(x: 1.3, y: 10, width: 9.4, height: 2); horizontal = true
        }
        if horizontal {
            return [CGPoint(x: box.minX + 1, y: box.minY), CGPoint(x: box.maxX - 1, y: box.minY),
                    CGPoint(x: box.maxX, y: box.midY), CGPoint(x: box.maxX - 1, y: box.maxY),
                    CGPoint(x: box.minX + 1, y: box.maxY), CGPoint(x: box.minX, y: box.midY)]
        }
        return [CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.minY + 1),
                CGPoint(x: box.maxX, y: box.maxY - 1), CGPoint(x: box.midX, y: box.maxY),
                CGPoint(x: box.minX, y: box.maxY - 1), CGPoint(x: box.minX, y: box.minY + 1)]
    }
}
