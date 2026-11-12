import BCRFoundation
import Foundation

/// Aligns the device's current temporary preset with the software configuration.
///
/// Input is a complete read-only BCL dump of the current preset. Output is the edited BCL for the
/// same temporary preset, without `$store`, `$recall` or `$global`, so a power cycle or preset
/// recall restores the stored original. MIDI identities of already learned controls never change.
public enum BCRPresetAlignment {
    public struct Options: Equatable, Sendable {
        /// Reassign identities for unconfigured buttons and buttons sharing an encoder identity.
        public var completeButtons = true
        /// Choose LED ring modes from parameter ranges (top encoders only; the lower 24 support dots only).
        public var ringModes = true
        /// Make every button report both press and release (`toggleoff`). The software owns toggle
        /// state and button LEDs, so the device must not latch or count locally.
        public var buttonBehavior = true
        /// Let buttons whose identity the device confirms execute their assigned functions instead
        /// of only showing presses. Host map only; nothing on the device changes. Off by default:
        /// physical presses may then trigger actions such as output enable.
        public var enableButtonFunctions = false
        /// `.lock on`: PRESET and function keys become buttons 53–56/63–64, so preset changes cannot
        /// silently diverge from the software.
        public var lockPreset = true

        public init() {}

        public init(completeButtons: Bool, ringModes: Bool, buttonBehavior: Bool, lockPreset: Bool,
                    enableButtonFunctions: Bool = false)
        {
            self.completeButtons = completeButtons; self.ringModes = ringModes
            self.buttonBehavior = buttonBehavior; self.lockPreset = lockPreset
            self.enableButtonFunctions = enableButtonFunctions
        }
    }

    public struct Change: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case newButton, readdressedButton, ringMode, buttonBehavior, lock, enabledFunction
        }

        public let kind: Kind
        public let control: BCRControlID?
        public let detail: String
    }

    public struct Plan: Sendable {
        /// Edited preset lines, `$rev R1` … `$end`; no store or recall.
        public let lines: [String]
        public let changes: [Change]
        /// Hardware map after the device accepts `lines`: identities, ring modes and press modes.
        public let hardwareMap: HardwareMap

        public var isEmpty: Bool { changes.isEmpty }

        /// BCL frames for the device, one acknowledged line each.
        public func frames(device: UInt8 = 0x7F) -> [[UInt8]] {
            lines.enumerated().map { index, line in
                [0xF0, 0, 0x20, 0x32, device, 0x15, 0x20, UInt8(index >> 7), UInt8(index & 127)]
                    + Array(line.utf8) + [0xF7]
            }
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case invalid(String)
        public var errorDescription: String? {
            if case let .invalid(reason) = self { return L10n.text("预设对齐失败：\(reason)") }
            return nil
        }
    }

    /// Device button number for each button control.
    public static func buttonNumber(for control: BCRControlID) -> Int? {
        switch control.section {
        case .pushEncoderButton: (control.row - 1) * 8 + control.index
        case .button: 32 + (control.row - 1) * 8 + control.index
        case .userButton: 48 + control.index
        case .pushEncoder, .encoder: nil
        }
    }

    public static func encoderNumber(for control: BCRControlID) -> Int? {
        switch control.section {
        case .pushEncoder: (control.row - 1) * 8 + control.index
        case .encoder: 32 + (control.row - 1) * 8 + control.index
        case .pushEncoderButton, .button, .userButton: nil
        }
    }

    /// Ring mode for a top encoder, or nil to keep the device's mode. A range symmetric around zero
    /// reads as a pan, a unit range starting at zero (e.g. percent) as a bar. Raw, unit-less
    /// 0…127 parameters carry no meaning to show, so their existing mode is kept.
    public static func ringMode(for definition: ParameterDefinition) -> LEDRingMode? {
        let span = definition.maximum - definition.minimum
        guard span > 0, definition.kind == .continuous else { return nil }
        if definition.minimum < 0, abs(definition.minimum + definition.maximum) <= span * 0.02 { return .pan }
        if definition.minimum == 0, !definition.unit.trimmingCharacters(in: .whitespaces).isEmpty { return .bar }
        return nil
    }

    public static func prepare(
        dump: Data, hardwareMap: HardwareMap, configuration: SurfaceConfiguration, options: Options = .init()
    ) throws -> Plan {
        let source = try BCRPresetEncoderLearning.decodeLines(dump)
        guard source.first == "$rev R1", source.last == "$end",
              source.filter({ $0 == "$preset" }).count == 1,
              !source.contains(where: { $0.hasPrefix("$store") || $0.hasPrefix("$recall") || $0.hasPrefix("$global") })
        else { throw Failure.invalid(L10n.text("需要完整的单个当前预设")) }
        var document = try Document(lines: source)
        guard document.setting(".egroups") == "4" else {
            throw Failure.invalid(L10n.text("只支持 4 个编码器组的预设"))
        }
        var map = try hardwareMap.migrated()
        var changes: [Change] = []

        // Identities already used by encoders or other buttons; a reassigned button must avoid all.
        var used = Set<MIDIControlID>()
        var encoderIDs: [Int: MIDIControlID] = [:]
        for (number, block) in document.encoders {
            guard let id = block.easyparIdentity else { continue }
            encoderIDs[number] = id; used.insert(id)
        }
        let encoderIdentities = Set(encoderIDs.values)
        var buttonIDs: [Int: MIDIControlID] = [:]
        for (number, block) in document.buttons where (1 ... 52).contains(number) {
            guard let id = block.easyparIdentity, !encoderIdentities.contains(id) else { continue }
            if buttonIDs.values.contains(id) { continue }
            buttonIDs[number] = id; used.insert(id)
        }

        // Every encoder the software knows must still be exactly what the device sends.
        for entry in map.entries where entry.control.isContinuous {
            guard let number = encoderNumber(for: entry.control), encoderIDs[number] == entry.midi else {
                throw Failure.invalid(L10n.text("\(entry.control.shortName) 与设备预设不一致，请先重新学习"))
            }
        }

        let buttons = BCRLayout.allControls.filter { !$0.isContinuous }
        if options.completeButtons {
            var free = (0 ... 127).lazy.map { MIDIControlID(kind: .controlChange, channel: 15, number: UInt8($0)) }
                .filter { !used.contains($0) }.makeIterator()
            for control in buttons {
                guard let number = buttonNumber(for: control) else { continue }
                if let id = buttonIDs[number] {
                    if let learned = map.midi(for: control), learned != id {
                        throw Failure.invalid(L10n.text("\(control.shortName) 与设备预设不一致，请先重新学习"))
                    }
                    continue
                }
                if let learned = map.midi(for: control), !map.isVisualizationOnly(control) {
                    // A functional binding the device doesn't send: report rather than silently change it.
                    throw Failure.invalid(L10n.text("\(control.shortName) 的已学习身份 \(learned) 不在设备预设中"))
                }
                guard let id = free.next() else { throw Failure.invalid(L10n.text("没有可用的 MIDI 地址")) }
                let wasDefined = document.buttons[number]?.easyparIdentity != nil
                document.setButton(number, easypar: ".easypar CC 16 \(id.number) 127 0 toggleoff")
                buttonIDs[number] = id; used.insert(id)
                map.unbind(control)
                try map.bind(control, to: id, visualizationOnly: true, pressMode: .momentary)
                changes.append(Change(kind: wasDefined ? .readdressedButton : .newButton, control: control,
                                      detail: "CC \(id.number) ch16"))
            }
        }

        if options.buttonBehavior {
            for control in buttons {
                guard let number = buttonNumber(for: control), let id = buttonIDs[number],
                      let block = document.buttons[number], let words = block.easyparWords,
                      ["CC", "NOTE"].contains(words[1]), words.count >= (words[1] == "NOTE" ? 6 : 7)
                else { continue }
                // Press sends the on value, release sends 0; never a local latch or counter.
                // NOTE syntax has a single velocity; its release is always velocity 0.
                let edited = (words[1] == "NOTE"
                    ? Array(words[0 ..< 5]) + ["toggleoff"]
                    : Array(words[0 ..< 4]) + ["127", "0", "toggleoff"]).joined(separator: " ")
                if words != edited.split(separator: " ").map(String.init) {
                    document.setButton(number, easypar: edited)
                    changes.append(Change(kind: .buttonBehavior, control: control, detail: L10n.text("按下/松开")))
                }
                if map.midi(for: control) == id, map.pressMode(for: control) != .momentary {
                    try map.bind(control, to: id, visualizationOnly: map.isVisualizationOnly(control),
                                 pressMode: .momentary)
                }
            }
        }

        if options.enableButtonFunctions {
            for control in buttons {
                guard let number = buttonNumber(for: control), let id = buttonIDs[number],
                      map.midi(for: control) == id, map.isVisualizationOnly(control) else { continue }
                try map.bind(control, to: id, visualizationOnly: false, pressMode: map.pressMode(for: control))
                if configuration.assignment(for: control) != nil {
                    changes.append(Change(kind: .enabledFunction, control: control, detail: L10n.text("启用功能")))
                }
            }
        }

        if options.ringModes {
            for number in 1 ... 32 {
                let control = BCRControlID.pushEncoder(group: (number - 1) / 8 + 1, (number - 1) % 8 + 1)
                guard let assignment = configuration.assignment(for: control),
                      case let .parameter(id) = assignment.target, assignment.encoderMode == .absolute,
                      let definition = configuration.parameter(id), let midi = map.midi(for: control)
                else { continue }
                guard let mode = ringMode(for: definition) else { continue }
                if document.encoders[number]?.value(of: ".mode") != mode.rawValue {
                    document.setEncoder(number, statement: ".mode", value: mode.rawValue)
                    changes.append(Change(kind: .ringMode, control: control, detail: mode.rawValue))
                }
                try map.bind(control, to: midi, ringMode: mode)
            }
        }

        if options.lockPreset, document.setting(".lock") != "on" {
            document.setSetting(".lock", value: "on")
            changes.append(Change(kind: .lock, control: nil, detail: ".lock on"))
        }

        let lines = document.render()
        guard lines.allSatisfy({ $0.utf8.count <= 120 && $0.utf8.allSatisfy { (32 ... 126).contains($0) } }) else {
            throw Failure.invalid(L10n.text("生成的 BCL 行无效"))
        }
        try map.validate()
        return Plan(lines: lines, changes: changes, hardwareMap: map)
    }
}

/// Minimal structured BCL preset: header settings, then encoder/button sections in order.
private struct Document {
    struct Block {
        var header: String
        var statements: [String]

        var easyparWords: [String]? {
            statements.first { $0.hasPrefix(".easypar ") }?.split(separator: " ").map(String.init)
        }

        var easyparIdentity: MIDIControlID? {
            guard let words = easyparWords, words.count >= 4,
                  let channel = UInt8(words[2]), (1 ... 16).contains(channel),
                  let number = UInt8(words[3]), number < 128 else { return nil }
            switch words[1] {
            case "CC": return MIDIControlID(kind: .controlChange, channel: channel - 1, number: number)
            case "NOTE": return MIDIControlID(kind: .note, channel: channel - 1, number: number)
            default: return nil
            }
        }

        func value(of statement: String) -> String? {
            statements.first { $0.hasPrefix(statement + " ") }.map { String($0.dropFirst(statement.count + 1)) }
        }
    }

    var settings: [String]
    var blocks: [Block]

    init(lines: [String]) throws {
        var settings: [String] = [], blocks: [Block] = []
        var inPreset = false
        for line in lines.dropFirst().dropLast() {
            if line == "$preset" { inPreset = true; continue }
            if line.hasPrefix("$encoder ") || line.hasPrefix("$button ") {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let number = Int(parts[1]),
                      (1 ... 64).contains(number) else { throw BCRPresetAlignment.Failure.invalid(line) }
                blocks.append(Block(header: line, statements: []))
                continue
            }
            guard !line.hasPrefix("$") else {
                throw BCRPresetAlignment.Failure.invalid(L10n.text("不支持的预设区块"))
            }
            if blocks.isEmpty {
                guard inPreset else { throw BCRPresetAlignment.Failure.invalid(L10n.text("需要完整的单个当前预设")) }
                settings.append(line)
            } else {
                blocks[blocks.count - 1].statements.append(line)
            }
        }
        self.settings = settings
        self.blocks = blocks
    }

    private func sections(_ prefix: String) -> [Int: Block] {
        var result: [Int: Block] = [:]
        for block in blocks where block.header.hasPrefix(prefix) {
            if let number = Int(block.header.dropFirst(prefix.count)) { result[number] = block }
        }
        return result
    }

    var encoders: [Int: Block] { sections("$encoder ") }
    var buttons: [Int: Block] { sections("$button ") }

    func setting(_ name: String) -> String? {
        settings.first { $0.hasPrefix(name + " ") }.map { String($0.dropFirst(name.count + 1)) }
    }

    mutating func setSetting(_ name: String, value: String) {
        let line = "\(name) \(value)"
        if let index = settings.firstIndex(where: { $0.hasPrefix(name + " ") }) { settings[index] = line }
        else if let index = settings.firstIndex(of: ".init") { settings.insert(line, at: index) }
        else { settings.append(line) }
    }

    mutating func setButton(_ number: Int, easypar: String) {
        let header = "$button \(number)"
        if let index = blocks.firstIndex(where: { $0.header == header }) {
            blocks[index].statements
                .removeAll { $0.hasPrefix(".easypar ") || $0.hasPrefix(".tx ") || $0.hasPrefix(".mode ") }
            blocks[index].statements.insert(easypar, at: 0)
            if !blocks[index].statements.contains(where: { $0.hasPrefix(".showvalue ") }) {
                blocks[index].statements.insert(".showvalue on", at: 1)
            }
        } else {
            blocks.append(Block(header: header, statements: [easypar, ".showvalue on", ".default 0"]))
        }
    }

    mutating func setEncoder(_ number: Int, statement: String, value: String) {
        let header = "$encoder \(number)"
        let line = "\(statement) \(value)"
        guard let index = blocks.firstIndex(where: { $0.header == header }) else { return }
        if let position = blocks[index].statements.firstIndex(where: { $0.hasPrefix(statement + " ") }) {
            blocks[index].statements[position] = line
        } else {
            blocks[index].statements.append(line)
        }
    }

    func render() -> [String] {
        ["$rev R1", "$preset"] + settings + blocks.flatMap { [$0.header] + $0.statements } + ["$end"]
    }
}
