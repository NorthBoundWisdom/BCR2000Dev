import Foundation

/// Four physical seven-segment cells. Bits 0...6 are a (top), b, c, d (bottom),
/// e, f, g (middle), clockwise from the top. No font or device writes are involved.
public enum BCRSevenSegmentDisplay {
    private static let glyphs: [Character: UInt8] = [
        "0": 0x3F, "1": 0x06, "2": 0x5B, "3": 0x4F, "4": 0x66,
        "5": 0x6D, "6": 0x7D, "7": 0x07, "8": 0x7F, "9": 0x6F,
        "P": 0x73, "-": 0x40, " ": 0, "o": 0x5C, "n": 0x54, "F": 0x71
    ]

    /// Right-align the logical display value. Unsupported cells show the same dash
    /// as an unknown preset, rather than substituting a typographic character.
    public static func masks(for text: String) -> [UInt8] {
        let cells = Array(text.suffix(4))
        return Array(repeating: 0, count: 4 - cells.count) + cells.map { glyphs[$0] ?? 0x40 }
    }

    /// The existing twelve-step transfer outline, encoded on these same digit cells.
    public static func busyMasks(frame: Int) -> [UInt8] {
        var result: [UInt8] = [0, 0, 0, 0]
        switch frame {
        case 0 ... 3: result[frame] = 0x01
        case 4: result[3] = 0x02
        case 5: result[3] = 0x04
        case 6 ... 9: result[9 - frame] = 0x08
        case 10: result[0] = 0x10
        case 11: result[0] = 0x20
        default: return [0x40, 0x40, 0x40, 0x40]
        }
        return result
    }
}
