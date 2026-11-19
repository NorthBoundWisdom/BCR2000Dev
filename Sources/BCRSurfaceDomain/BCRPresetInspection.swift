import Foundation

/// A read-only inventory of BCR2000 BCL files for comparing presets before learning.
public enum BCRPresetInspection {
    public static let maximumFileBytes = 4 * 1024 * 1024

    public enum Format: Sendable { case text, sysEx }

    public enum Failure: LocalizedError {
        case invalidText, incompleteBlock, invalidElement(line: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidText: "Expected a non-empty UTF-8 BCL file within the size limit."
            case .incompleteBlock: "Expected a complete BCR2000 block from $rev R1 through $end."
            case let .invalidElement(line): "Invalid BCR2000 encoder or button selector at line \(line)."
            }
        }
    }

    public struct Address: Encodable, Hashable, Sendable {
        public enum Message: String, Encodable, Sendable { case cc = "CC", nrpn = "NRPN", note = "NOTE" }
        public let message: Message
        public let channel: Int
        public let number: Int
    }

    public struct Binding: Encodable, Sendable {
        public let line: Int
        public let address: Address
        public let mode: String
        public let dataBits: Int?
        public let value1: Int
        public let value2: Int?
        public let incrementStep: Int?
    }

    public struct Element: Encodable, Sendable {
        public enum Kind: String, Encodable, Sendable { case encoder, button }
        public let line: Int
        public let kind: Kind
        public let number: Int
        public fileprivate(set) var bindings: [Binding] = []
        public fileprivate(set) var unsupportedEasyparLines: [Int] = []
        public fileprivate(set) var customOutputLines: [Int] = []
        public fileprivate(set) var minMax: [Int]?
    }

    public struct Preset: Encodable, Sendable {
        public let line: Int
        public fileprivate(set) var encoderGroups: Int?
        public fileprivate(set) var learnOutputLines: [Int] = []
        public fileprivate(set) var elements: [Element] = []
        public fileprivate(set) var duplicateAddresses: [[Binding]] = []

        fileprivate mutating func findDuplicates() {
            let byAddress = Dictionary(grouping: elements.flatMap(\.bindings), by: \.address)
            duplicateAddresses = byAddress.values.filter { $0.count > 1 }.sorted { $0[0].line < $1[0].line }
        }
    }

    public struct Directive: Encodable, Sendable {
        public enum Kind: String, Encodable, Sendable { case store, recall, global }
        public let line: Int
        public let kind: Kind
        public let slot: Int?
    }

    public struct Report: Encodable, Sendable {
        public fileprivate(set) var presets: [Preset] = []
        public fileprivate(set) var directives: [Directive] = []
    }

    public static func inspect(_ data: Data, format: Format) throws -> Report {
        let lines: [String]
        switch format {
        case .text:
            guard !data.isEmpty, data.count <= maximumFileBytes,
                  let source = String(data: data, encoding: .utf8), !source.contains("\0")
            else { throw Failure.invalidText }
            let text = source.first == "\u{FEFF}" ? source.dropFirst() : source[...]
            lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        case .sysEx:
            lines = try BCRPresetEncoderLearning.decodeLines(data, allowFileBroadcastAddress: true)
        }

        var report = Report(), inBlock = false
        var preset: Int?, element: Int?
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let words = statement(in: line).split(whereSeparator: \.isWhitespace)
            guard let command = words.first else { continue }
            if command == "$rev" {
                guard !inBlock, words == ["$rev", "R1"] else { throw Failure.incompleteBlock }
                inBlock = true
                continue
            }
            guard inBlock else { throw Failure.incompleteBlock }
            switch command {
            case "$end":
                guard words.count == 1 else { throw Failure.incompleteBlock }
                inBlock = false
                preset = nil
                element = nil
            case "$preset":
                guard words.count == 1 else { throw Failure.incompleteBlock }
                preset = report.presets.count
                report.presets.append(Preset(line: lineNumber))
                element = nil
            case "$global", "$store", "$recall":
                let kind: Directive.Kind = command == "$store" ? .store : (command == "$recall" ? .recall : .global)
                let slot = words.count == 2 ? number(words[1]) : nil
                report.directives.append(Directive(line: lineNumber, kind: kind, slot: slot))
                preset = nil
                element = nil
            case "$encoder", "$button":
                let kind: Element.Kind = command == "$encoder" ? .encoder : .button
                guard let preset, words.count == 2, let id = number(words[1]),
                      (1 ... (kind == .encoder ? 56 : 64)).contains(id)
                else { throw Failure.invalidElement(line: lineNumber) }
                element = report.presets[preset].elements.count
                report.presets[preset].elements.append(Element(line: lineNumber, kind: kind, number: id))
            default:
                if command.hasPrefix("$") { throw Failure.incompleteBlock }
                guard let preset else { continue }
                if let element {
                    inspect(words, line: lineNumber, element: &report.presets[preset].elements[element])
                } else if command == ".egroups", words.count == 2 {
                    report.presets[preset].encoderGroups = number(words[1])
                } else if command == ".tx" {
                    report.presets[preset].learnOutputLines.append(lineNumber)
                }
            }
        }
        guard !inBlock, !report.presets.isEmpty || !report.directives.isEmpty else { throw Failure.incompleteBlock }
        for index in report.presets.indices { report.presets[index].findDuplicates() }
        return report
    }

    private static func inspect(_ words: [Substring], line: Int, element: inout Element) {
        switch words[0] {
        case ".tx": element.customOutputLines.append(line)
        case ".minmax":
            if words.count == 3, let first = number(words[1]), let second = number(words[2]) {
                element.minMax = [first, second]
            }
        case ".easypar":
            if let binding = binding(words, line: line, kind: element.kind) {
                element.bindings.append(binding)
            } else {
                element.unsupportedEasyparLines.append(line)
            }
        default: break
        }
    }

    private static func binding(_ words: [Substring], line: Int, kind: Element.Kind) -> Binding? {
        guard words.count >= 4, let message = Address.Message(rawValue: String(words[1])),
              let channel = number(words[2]), (1 ... 16).contains(channel),
              let id = number(words[3]), (0 ... (message == .nrpn ? 16383 : 127)).contains(id)
        else { return nil }
        let address = Address(message: message, channel: channel, number: id)
        if message == .note {
            guard kind == .button, words.count == 6, let velocity = number(words[4]), (0 ... 127).contains(velocity),
                  ["toggleon", "toggleoff"].contains(words[5])
            else { return nil }
            return Binding(line: line, address: address, mode: String(words[5]), dataBits: 7,
                           value1: 0, value2: velocity, incrementStep: nil)
        }
        guard words.count >= 7, let first = number(words[4]) else { return nil }
        let second = number(words[5])
        let mode = words[6]
        let base = mode.hasSuffix("/14") ? mode.dropLast(3) : mode
        let dataBits: Int?
        var incrementStep: Int?
        if kind == .encoder {
            guard words.count == 7, second != nil else { return nil }
            switch base {
            case "absolute", "relative-1", "relative-2", "relative-3":
                dataBits = mode == base || (message == .cc && id >= 32) ? 7 : 14
            case "inc/dec" where mode == base && message == .nrpn:
                dataBits = nil
            default: return nil
            }
        } else {
            guard second != nil || words[5] == "off" else { return nil }
            switch mode {
            case "toggleon", "toggleoff":
                guard words.count == 7 else { return nil }
            case "increment":
                guard words.count == 8, let step = number(words[7]), (-127 ... 127).contains(step), step != 0
                else { return nil }
                incrementStep = step
            default: return nil
            }
            dataBits = 7
        }
        return Binding(line: line, address: address, mode: String(mode), dataBits: dataBits,
                       value1: first, value2: second, incrementStep: incrementStep)
    }

    private static func number(_ word: Substring) -> Int? {
        word.first == "$" ? Int(word.dropFirst(), radix: 16) : Int(word)
    }

    private static func statement(in line: String) -> Substring {
        var quoted = false
        for index in line.indices {
            if line[index] == "'" { quoted.toggle() }
            if line[index] == ";", !quoted { return line[..<index] }
        }
        return line[...]
    }
}
