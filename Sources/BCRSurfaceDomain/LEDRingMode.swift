import Foundation

/// Device display metadata learned from BCL, independent of parameter bindings.
public enum LEDRingMode: String, Codable, Sendable, CaseIterable {
    case off
    case oneDot = "1dot"
    case oneDotOff = "1dot/off"
    case twoDot = "12dot"
    case twoDotOff = "12dot/off"
    case bar
    case barOff = "bar/off"
    case spread, pan, qual, cut, damp

    public static let count = 15

    /// Zero-based LEDs, clockwise from the lower left. Nil means not yet calibrated.
    /// Firmware 1.10 samples: 12dot 2→[0], 3→[0,1], 7→[1], 12→[1,2]; 1dot 5→[1].
    /// Bar and pan were compared against the device at 24 values on 2026-11-12, including each
    /// side of the boundaries 4/5, 13/14, 49/50, 58/59, 68/69 and 122/123: all matched.
    public func litLEDs(value: UInt8) -> Set<Int>? {
        let value = min(Int(value), 127)
        let dot = (value * 14 + 63) / 127
        switch self {
        case .off: return []
        case .oneDot: return [dot]
        case .oneDotOff: return value == 0 ? [] : [dot]
        case .twoDot, .twoDotOff:
            if self == .twoDotOff, value == 0 { return [] }
            let position = (value * 28 + 63) / 127
            let first = position / 2
            return position.isMultiple(of: 2) ? [first] : [first, first + 1]
        // Bar fills from the lower left to the position dot; pan spans the top LED and the dot.
        // bar/off is not hardware-checked (the device preset doesn't use it).
        case .bar, .barOff:
            if self == .barOff, value == 0 { return [] }
            return Set(0 ... dot)
        case .pan:
            let center = (LEDRingMode.count - 1) / 2
            return Set(min(dot, center) ... max(dot, center))
        case .spread, .qual, .cut, .damp: return nil
        }
    }
}
