import BCRFoundation
import Foundation

public enum HardwarePressMode: String, Codable, Sendable { case momentary, pulse }

public struct HardwareMapEntry: Hashable, Codable, Sendable {
    public let control: BCRControlID
    public let midi: MIDIControlID
    public let ringMode: LEDRingMode?
    public let visualizationOnly: Bool?
    public let pressMode: HardwarePressMode?

    public init(
        control: BCRControlID,
        midi: MIDIControlID,
        ringMode: LEDRingMode? = nil,
        visualizationOnly: Bool = false,
        pressMode: HardwarePressMode? = nil
    ) {
        self.control = control
        self.midi = midi
        self.ringMode = ringMode
        self.visualizationOnly = visualizationOnly ? true : nil
        self.pressMode = pressMode
    }
}

public enum HardwareBindingError: Error, Equatable, LocalizedError, Sendable {
    /// The MIDI message is already the identity of another physical control.
    case alreadyBound(MIDIControlID, to: BCRControlID)
    /// Encoders must send CC or NRPN so the app can write their LED ring back.
    case encoderRequiresControlChange(BCRControlID)
    case invalidMap(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidMap(reason): reason
        case let .alreadyBound(midi, control):
            L10n.text("\(midi) 已绑定到 \(control.shortName)，请先清除该绑定")
        case let .encoderRequiresControlChange(control):
            L10n.text("\(control.shortName) 是编码器，只能学习 CC 或 NRPN 消息")
        }
    }
}

/// Physical control ↔ MIDI identity, as sent by one concrete BCR2000 preset.
/// Real-device maps are only created by explicit learning; the mock device has its own preset.
public struct HardwareMap: Equatable, Codable, Sendable {
    /// Version 4 adds 14-bit NRPN identities; v3 is migrated without losing bindings.
    /// Version 3 replaces the slot-only `ControllerProfile` with a full physical surface map.
    /// Version 5 preserves explicitly learned LED display modes; old maps retain unknown modes.
    /// Version 6 adds button observations that cannot execute functions or send feedback.
    /// Version 7 records actual press/release versus counter-pulse message behavior.
    public static let currentVersion = 7

    public var version: Int
    public private(set) var entries: [HardwareMapEntry]

    public init(version: Int = HardwareMap.currentVersion, entries: [HardwareMapEntry] = []) {
        self.version = version
        self.entries = entries.sorted { $0.control < $1.control }
    }

    private enum CodingKeys: String, CodingKey { case version, entries }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try container.decode(Int.self, forKey: .version),
                  entries: try container.decode([HardwareMapEntry].self, forKey: .entries))
        try validate()
    }

    public var boundCount: Int {
        entries.count
    }

    public func midi(for control: BCRControlID) -> MIDIControlID? {
        entries.first { $0.control == control }?.midi
    }

    public func ringMode(for control: BCRControlID) -> LEDRingMode? {
        entries.first { $0.control == control }?.ringMode
    }

    public func isVisualizationOnly(_ control: BCRControlID) -> Bool {
        entries.first { $0.control == control }?.visualizationOnly == true
    }

    public func pressMode(for control: BCRControlID) -> HardwarePressMode? {
        entries.first { $0.control == control }?.pressMode
    }

    public func control(for midi: MIDIControlID) -> BCRControlID? {
        entries.first { $0.midi == midi }?.control
    }

    /// Binds `control` to `midi`, replacing an earlier binding of the same control.
    public mutating func bind(
        _ control: BCRControlID, to midi: MIDIControlID, ringMode: LEDRingMode? = nil, visualizationOnly: Bool = false,
        pressMode: HardwarePressMode? = nil
    ) throws(HardwareBindingError) {
        if control.isContinuous, midi.kind == .note {
            throw HardwareBindingError.encoderRequiresControlChange(control)
        }
        if let existing = self.control(for: midi), existing != control {
            throw HardwareBindingError.alreadyBound(midi, to: existing)
        }
        var candidate = self
        candidate.entries.removeAll { $0.control == control }
        let mode = ringMode ?? (self.midi(for: control) == midi ? self.ringMode(for: control) : nil)
        if (visualizationOnly || pressMode != nil),
           control.isContinuous { throw .invalidMap(L10n.text("按压预览绑定只能用于按钮")) }
        candidate.entries.append(HardwareMapEntry(
            control: control,
            midi: midi,
            ringMode: mode,
            visualizationOnly: visualizationOnly,
            pressMode: pressMode ?? (self.midi(for: control) == midi ? self.pressMode(for: control) : nil)
        ))
        candidate.entries.sort { $0.control < $1.control }
        do { try candidate.validate() } catch { throw .invalidMap(error.localizedDescription) }
        self = candidate
    }

    public mutating func unbind(_ control: BCRControlID) {
        entries.removeAll { $0.control == control }
    }

    public mutating func reset() {
        entries.removeAll()
    }

    /// The deterministic preset of the built-in mock device. It describes only the mock and is
    /// never applied to a real BCR2000: all CCs on MIDI channel 1, numbered in panel order
    /// (push encoders 1–32, encoder push 33–64, buttons 65–80, encoders 81–104, user 105–108).
    public static func mockPreset() -> HardwareMap {
        let entries = BCRLayout.allControls.enumerated().map { offset, control in
            HardwareMapEntry(
                control: control,
                midi: MIDIControlID(kind: .controlChange, channel: 0, number: UInt8(offset + 1)),
                ringMode: control.isContinuous ? (control.section == .pushEncoder ? .twoDot : .oneDot) : nil,
                pressMode: control.isContinuous ? nil : .momentary
            )
        }
        return HardwareMap(entries: entries)
    }
}
