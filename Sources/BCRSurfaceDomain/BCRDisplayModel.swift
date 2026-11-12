import BCRFoundation
import Foundation

/// What the BCR2000's 4-digit, 7-segment display shows, reconstructed from what the host can
/// observe. The device never reports its display, so this follows the documented firmware rules:
///
/// - Play mode shows the preset number (rendered " P 8"; exact device format unverified); the host
///   only knows it after loading one itself.
/// - Moving an element with ShowValue on briefly shows its raw MIDI value (4 digits, so 10000+ loses
///   its leading 1).
/// - Buttons with ShowValue on show "on" while pressed and "oFF" on release (toggleoff); a counter
///   (increment) shows the new value.
/// - Values written *to* the device are not shown; only local manipulation is.
public struct BCRDisplayModel: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case preset(Int)
        case value(Int)
        case on
        case off
        case unknown
    }

    /// How long the device keeps a value before returning to the preset number.
    public static let holdSeconds: Double = 1.5

    public private(set) var preset: Int?
    public private(set) var transient: (content: Content, until: Double)?

    public init(preset: Int? = nil) { self.preset = preset }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.preset == rhs.preset && lhs.transient?.content == rhs.transient?.content
            && lhs.transient?.until == rhs.transient?.until
    }

    public mutating func setPreset(_ preset: Int?) {
        self.preset = preset.flatMap { (1 ... 32).contains($0) ? $0 : nil }
    }

    /// An encoder moved on the device; `rawValue` is the full value it sent.
    public mutating func encoderMoved(rawValue: Int, showsValue: Bool, at time: Double) {
        guard showsValue else { return }
        transient = (.value(rawValue), time + Self.holdSeconds)
    }

    /// A button was pressed or released on the device. `pressed` is nil for counters, which show
    /// the value they sent.
    public mutating func buttonChanged(pressed: Bool?, rawValue: Int, showsValue: Bool, at time: Double) {
        guard showsValue else { return }
        let content: Content = switch pressed {
        case true?: .on
        case false?: .off
        case nil: .value(rawValue)
        }
        transient = (content, time + Self.holdSeconds)
    }

    public mutating func clearTransient() { transient = nil }

    public func content(at time: Double) -> Content {
        if let transient, time < transient.until { return transient.content }
        return preset.map(Content.preset) ?? .unknown
    }

    /// The four characters as the 7-segment display would render them.
    public static func text(for content: Content) -> String {
        switch content {
        case let .preset(number): pad("P" + (number < 10 ? " " : "") + String(number))
        case let .value(value): pad(String(String(max(value, 0)).suffix(4)))
        case .on: pad("on")
        case .off: pad("oFF")
        case .unknown: "----"
        }
    }

    private static func pad(_ text: String) -> String {
        String(repeating: " ", count: max(0, 4 - text.count)) + text
    }
}

/// Per-control `.showvalue` settings and the preset name, read from a device preset dump.
/// Kept apart from the hardware map: it describes the display, not MIDI identities.
public struct BCRDisplayProfile: Codable, Equatable, Sendable {
    public var name: String?
    public var silentControls: Set<BCRControlID>

    public init(name: String? = nil, silentControls: Set<BCRControlID> = []) {
        self.name = name; self.silentControls = silentControls
    }

    /// The device default for an element without a `.showvalue` statement is on.
    public func showsValue(_ control: BCRControlID) -> Bool { !silentControls.contains(control) }

    public static func read(fromPresetDump dump: Data) throws -> BCRDisplayProfile {
        let lines = try BCRPresetEncoderLearning.decodeLines(dump)
        guard lines.first == "$rev R1", lines.last == "$end" else {
            throw BCRPresetAlignment.Failure.invalid(L10n.text("需要完整的单个当前预设"))
        }
        var profile = BCRDisplayProfile()
        var control: BCRControlID?
        for line in lines {
            if line.hasPrefix("$") {
                control = nil
                let parts = line.split(separator: " ")
                guard parts.count == 2, let number = Int(parts[1]) else { continue }
                if parts[0] == "$encoder", (1 ... 56).contains(number) {
                    control = number <= 32
                        ? .pushEncoder(group: (number - 1) / 8 + 1, (number - 1) % 8 + 1)
                        : .encoder(row: (number - 33) / 8 + 1, (number - 33) % 8 + 1)
                } else if parts[0] == "$button", (1 ... 52).contains(number) {
                    control = number <= 32 ? .pushEncoderButton(group: (number - 1) / 8 + 1, (number - 1) % 8 + 1)
                        : number <= 48 ? .button(row: (number - 33) / 8 + 1, (number - 33) % 8 + 1)
                        : .userButton(number - 48)
                }
            } else if line.hasPrefix(".name '"), line.hasSuffix("'"), control == nil {
                let name = line.dropFirst(7).dropLast().trimmingCharacters(in: .whitespaces)
                profile.name = name.isEmpty ? nil : name
            } else if let current = control {
                // `.easypar` resets ShowValue to off; a later `.showvalue` statement wins.
                if line.hasPrefix(".easypar ") || line == ".showvalue off" { profile.silentControls.insert(current) }
                if line == ".showvalue on" { profile.silentControls.remove(current) }
            }
        }
        return profile
    }
}
