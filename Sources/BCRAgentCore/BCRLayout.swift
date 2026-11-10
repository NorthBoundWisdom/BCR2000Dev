import Foundation

/// Physical sections of the BCR2000 front panel. This is fixed hardware geometry, not preset
/// content: which MIDI message a control sends is defined by the user's preset and is resolved
/// through `HardwareMap`.
public enum BCRSection: String, Codable, Sendable, CaseIterable, Comparable {
    /// Top row of 8 push encoders with LED rings, switchable across 4 encoder groups.
    case pushEncoder
    /// The push (click) function of each top encoder, also per encoder group.
    case pushEncoderButton
    /// Two rows of 8 LED buttons below the push encoders.
    case button
    /// Three rows of 8 encoders with LED rings.
    case encoder
    /// The 4 user buttons at the lower right.
    case userButton

    public var rowRange: ClosedRange<Int> {
        switch self {
        case .pushEncoder, .pushEncoderButton: 1 ... 4
        case .button: 1 ... 2
        case .encoder: 1 ... 3
        case .userButton: 1 ... 1
        }
    }

    public var indexRange: ClosedRange<Int> {
        self == .userButton ? 1 ... 4 : 1 ... 8
    }

    /// Encoders send a continuous 7-bit value; every other section is a button.
    public var isContinuous: Bool {
        self == .pushEncoder || self == .encoder
    }

    public var displayName: String {
        switch self {
        case .pushEncoder: "推钮编码器"
        case .pushEncoderButton: "编码器按下"
        case .button: "按键"
        case .encoder: "编码器"
        case .userButton: "用户按键"
        }
    }

    private var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    public static func < (lhs: BCRSection, rhs: BCRSection) -> Bool {
        lhs.order < rhs.order
    }
}

/// One physical control. `row` is the encoder group for the top encoders (1...4), the row for
/// buttons (1...2) and encoders (1...3), and always 1 for user buttons.
public struct BCRControlID: Hashable, Codable, Sendable, Comparable, Identifiable, CustomStringConvertible {
    public let section: BCRSection
    public let row: Int
    public let index: Int

    public var id: BCRControlID { self }

    public init(section: BCRSection, row: Int, index: Int) {
        precondition(section.rowRange.contains(row), "Row \(row) is outside \(section)")
        precondition(section.indexRange.contains(index), "Index \(index) is outside \(section)")
        self.section = section
        self.row = row
        self.index = index
    }

    public static func pushEncoder(group: Int, _ index: Int) -> BCRControlID {
        BCRControlID(section: .pushEncoder, row: group, index: index)
    }

    public static func pushEncoderButton(group: Int, _ index: Int) -> BCRControlID {
        BCRControlID(section: .pushEncoderButton, row: group, index: index)
    }

    public static func button(row: Int, _ index: Int) -> BCRControlID {
        BCRControlID(section: .button, row: row, index: index)
    }

    public static func encoder(row: Int, _ index: Int) -> BCRControlID {
        BCRControlID(section: .encoder, row: row, index: index)
    }

    public static func userButton(_ index: Int) -> BCRControlID {
        BCRControlID(section: .userButton, row: 1, index: index)
    }

    public var isContinuous: Bool {
        section.isContinuous
    }

    /// Compact panel label, e.g. `P2-3`, `B1-5`, `E3-8`, `U4`.
    public var shortName: String {
        switch section {
        case .pushEncoder: "P\(row)-\(index)"
        case .pushEncoderButton: "P\(row)-\(index)⏎"
        case .button: "B\(row)-\(index)"
        case .encoder: "E\(row)-\(index)"
        case .userButton: "U\(index)"
        }
    }

    public var description: String {
        switch section {
        case .pushEncoder, .pushEncoderButton:
            "\(section.displayName) 组\(row) #\(index)"
        case .button, .encoder:
            "\(section.displayName) 第\(row)行 #\(index)"
        case .userButton:
            "\(section.displayName) #\(index)"
        }
    }

    public static func < (lhs: BCRControlID, rhs: BCRControlID) -> Bool {
        (lhs.section, lhs.row, lhs.index) < (rhs.section, rhs.row, rhs.index)
    }

    // Codable keeps the precondition-validated initializer as the only way to build an ID.
    private enum CodingKeys: String, CodingKey {
        case section, row, index
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let section = try container.decode(BCRSection.self, forKey: .section)
        let row = try container.decode(Int.self, forKey: .row)
        let index = try container.decode(Int.self, forKey: .index)
        guard section.rowRange.contains(row), section.indexRange.contains(index) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Invalid BCR2000 control \(section) \(row)/\(index)"
                )
            )
        }
        self.init(section: section, row: row, index: index)
    }
}

public enum BCRLayout {
    public static let encoderGroups = BCRSection.pushEncoder.rowRange

    public static func controls(in section: BCRSection) -> [BCRControlID] {
        section.rowRange.flatMap { row in
            section.indexRange.map { BCRControlID(section: section, row: row, index: $0) }
        }
    }

    /// All 108 physical controls in panel order.
    public static let allControls: [BCRControlID] = BCRSection.allCases.flatMap(controls(in:))

    /// The next control after `control` in the same section, in panel reading order.
    public static func control(after control: BCRControlID) -> BCRControlID? {
        let sectionControls = controls(in: control.section)
        guard let position = sectionControls.firstIndex(of: control),
              position + 1 < sectionControls.count
        else {
            return nil
        }
        return sectionControls[position + 1]
    }
}
