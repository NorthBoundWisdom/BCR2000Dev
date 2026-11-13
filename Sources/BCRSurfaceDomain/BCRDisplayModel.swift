import BCRFoundation
import Foundation

/// What the BCR2000's 4-digit, 7-segment display shows, reconstructed from what the host can
/// observe. The device never reports its display, so this follows the documented firmware rules:
///
/// - Play mode shows the preset number as `P- 1` … `P-32` (observed on firmware 1.10). The device
///   doesn't report it; the host knows it after loading a preset or from a unique preset name.
/// - Moving an element with ShowValue on briefly shows its raw MIDI value (4 digits, so 10000+ loses
///   its leading 1).
/// - Buttons with ShowValue on show "on" while pressed and "oFF" on release (toggleoff); a counter
///   (increment) shows the new value.
/// - Values written *to* the device are not shown; only local manipulation is.
public struct BCRDisplayModel: Equatable, Sendable {
    public enum TransferOperation: Equatable, Sendable { case read, write }
    public enum Content: Equatable, Sendable {
        /// The device animates its display while it sends or receives a BCL preset dump.
        case busy
        case preset(Int)
        case value(Int)
        case on
        case off
        case unknown
    }

    /// Adjust these together after PLAN B4 hardware measurements. These are presentation estimates,
    /// not firmware constants or measured timing guarantees.
    public enum Calibration {
        /// 2026-11-12 user report: the device returns faster than 1.5 s. 0.8 s is still an estimate.
        public static let valueHoldSeconds: Double = 0.8
        /// 2026-11-13: clockwise; after previewing 2 rotations/s the user requested twice the speed.
        /// The resulting 4 rotations/s is a visual tuning choice, not a measured firmware rate.
        public static let busyRotationsPerSecond: Double = 4
        /// Outline indices are clockwise from the top left (see BusySegments in the host).
        public static let busyFrameSequence = Array(0 ..< 12)
        public static let busyFramesPerSecond = Double(busyFrameSequence.count) * busyRotationsPerSecond
        /// Explicit write observation, 2026-11-13: counterclockwise, approximately one turn/s.
        public static let writeBusyRotationsPerSecond: Double = 1
        public static let writeBusyFrameSequence = Array((0 ..< 12).reversed())

        public static func framesPerSecond(for operation: TransferOperation) -> Double {
            operation == .write
                ? Double(writeBusyFrameSequence.count) * writeBusyRotationsPerSecond : busyFramesPerSecond
        }
    }

    /// Compatibility spelling for the shared presentation calibration.
    public static let holdSeconds = Calibration.valueHoldSeconds

    public private(set) var preset: Int?
    /// Number of BCL transfers in flight (observed: the device animates for their whole duration).
    public private(set) var transfers = 0
    private var transferOperations: [(id: UUID, operation: TransferOperation)] = []
    public var transferOperation: TransferOperation {
        transferOperations.contains { $0.operation == .write } ? .write : .read
    }

    public private(set) var transient: (content: Content, until: Double)?

    public init(preset: Int? = nil) { self.preset = preset }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.preset == rhs.preset && lhs.transfers == rhs.transfers && lhs.transient?.content == rhs.transient?.content
            && lhs.transient?.until == rhs.transient?.until
            && lhs.transferOperations.map(\.operation) == rhs.transferOperations.map(\.operation)
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

    @discardableResult
    public mutating func beginTransfer(_ operation: TransferOperation = .read) -> UUID {
        let id = UUID()
        transferOperations.append((id, operation))
        transfers = transferOperations.count; transient = nil
        return id
    }

    public mutating func endTransfer(_ id: UUID? = nil) {
        if let id { transferOperations.removeAll { $0.id == id } }
        else if !transferOperations.isEmpty { transferOperations.removeLast() }
        transfers = transferOperations.count
    }

    public func content(at time: Double) -> Content {
        if transfers > 0 { return .busy }
        if let transient, time < transient.until { return transient.content }
        return preset.map(Content.preset) ?? .unknown
    }

    /// The four characters as the 7-segment display would render them.
    public static func text(for content: Content) -> String {
        switch content {
        case let .preset(number): number < 10 ? "P- \(number)" : "P-\(number)"
        case let .value(value): pad(String(String(max(value, 0)).suffix(4)))
        case .on: pad("on")
        case .off: pad("oFF")
        case .unknown: "----"
        case .busy: "----"
        }
    }

    /// Animation frame while busy, using the estimated timing and user-described order above.
    public static func busyFrame(at time: Double) -> Int {
        busyFrame(at: time, operation: .read)
    }

    public static func busyFrame(at time: Double, operation: TransferOperation) -> Int {
        let sequence = operation == .write ? Calibration.writeBusyFrameSequence : Calibration.busyFrameSequence
        let phase = Int((time * Calibration.framesPerSecond(for: operation)).rounded(.down)) % sequence.count
        return sequence[(phase + sequence.count) % sequence.count]
    }

    private static func pad(_ text: String) -> String {
        String(repeating: " ", count: max(0, 4 - text.count)) + text
    }
}

/// Names of the temporary preset and memory presets 1…32, as the device reports them.
public struct BCRPresetNames: Equatable, Sendable {
    public let temporary: String
    public let memory: [String]

    public init(temporary: String, memory: [String]) {
        self.temporary = temporary; self.memory = memory
    }

    /// The memory preset (1…32) the temporary preset was recalled from, identified by name.
    /// The device never reports its preset number. Its name survives temporary edits (such as
    /// alignment), so this follows what the display shows; a name shared by several presets or
    /// by none leaves the number unknown instead of guessing.
    public var presetNumber: Int? {
        let matches = candidates
        return matches.count == 1 ? matches[0] : nil
    }

    /// Memory presets (1…32) whose name equals the temporary preset's. Several candidates need a
    /// content comparison (see `resolve`); none means the number is unknown.
    public var candidates: [Int] {
        let key = Self.normalized(temporary)
        guard !key.isEmpty else { return [] }
        return memory.indices.filter { Self.normalized(memory[$0]) == key }.map { $0 + 1 }
    }

    /// Picks the one candidate whose element definitions equal the temporary preset. A temporary
    /// preset edited after recall (for example by alignment) matches none and stays unknown.
    public static func resolve(temporary: Data, candidates: [Int: Data]) throws -> Int? {
        let target = try signature(of: temporary)
        let matches = try candidates.filter { try signature(of: $0.value) == target }.map(\.key)
        return matches.count == 1 ? matches[0] : nil
    }

    /// Element definitions without per-element values (`.default`), which memory presets don't store.
    static func signature(of dump: Data) throws -> [String] {
        let lines = try BCRPresetEncoderLearning.decodeLines(dump)
        guard lines.first == "$rev R1", lines.last == "$end" else {
            throw BCRPresetAlignment.Failure.invalid(L10n.text("需要完整的单个当前预设"))
        }
        return lines.filter { !$0.hasPrefix(".default ") && !$0.hasPrefix("$store ") && !$0.hasPrefix("$recall ") }
    }

    public var temporaryName: String? {
        let name = Self.normalized(temporary)
        return name.isEmpty ? nil : name
    }

    private static func normalized(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces) }
}

/// Per-control `.showvalue` settings and the preset name, read from a device preset dump.
/// Kept apart from the hardware map: it describes the display, not MIDI identities.
public struct BCRDisplayProfile: Codable, Equatable, Sendable {
    public var name: String?
    public var silentControls: Set<BCRControlID>
    /// Preset number resolved by content when several memory presets share this name, with the
    /// candidate list it was resolved for. Reused while the device reports the same names, so the
    /// slow dumps run once rather than on every connection.
    public var resolvedPreset: Int?
    public var resolvedCandidates: [Int]?
    /// `.lock on` in the preset: PRESET and the function keys act as plain buttons 63–64 / 53–56
    /// instead of changing presets or entering the device's programming modes. Nil when unread.
    public var locked: Bool?

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
            } else if line == ".lock on" || line == ".lock off", control == nil {
                profile.locked = line == ".lock on"
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
