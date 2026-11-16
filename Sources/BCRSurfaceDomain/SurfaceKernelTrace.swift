import Foundation

/// Default-off Debug observation tap: records real inputs and actual Kit results.
/// It contains no legacy algorithm, comparison, authorization or business value owner.
enum SurfaceKernelTrace {
    #if DEBUG
        private static let recorder = Recorder()
        static var enabled: Bool { recorder.enabled }
        static func record(_ operation: String, owner: String = "stateless", input: [String: Any],
                           actual: [String: Any])
        {
            guard recorder.enabled else { return }
            recorder.record(operation, owner: owner, input: input, actual: actual)
        }

        private final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private let file: FileHandle?
            private var sequence = 0
            private var catalogues: [Data: String] = [:]
            var enabled: Bool { file != nil }
            init() {
                guard let path = ProcessInfo.processInfo.environment["BCR_J3_SHADOW_ROOT"] else {
                    file = nil; return
                }
                do {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let target = directory.appendingPathComponent(
                        "operations-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).jsonl"
                    )
                    guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                        fatalError("Cannot create J3 operation trace")
                    }
                    file = try FileHandle(forWritingTo: target)
                } catch { fatalError("Cannot open J3 operation trace: \(error)") }
            }

            func record(_ operation: String, owner: String, input: [String: Any], actual: [String: Any]) {
                lock.lock(); defer { lock.unlock() }
                do {
                    var recordedInput = input
                    for key in ["ordered_assignments", "ordered_controls", "entries"] {
                        guard let value = input[key] else { continue }
                        let content = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                        let identifier: String
                        if let existing = catalogues[content] { identifier = existing }
                        else {
                            identifier = "catalogue.\(catalogues.count)"
                            catalogues[content] = identifier
                            sequence += 1
                            try write(["sequence": sequence, "record_kind": "catalogue",
                                       "catalogue_id": identifier, "value": value])
                        }
                        recordedInput[key] = ["$catalogue": identifier]
                    }
                    sequence += 1
                    try write(["sequence": sequence, "record_kind": "operation", "operation": operation,
                               "owner": owner, "input": recordedInput, "actual": actual])
                } catch { fatalError("Cannot write J3 operation trace: \(error)") }
            }

            private func write(_ record: [String: Any]) throws {
                var bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                bytes.append(10)
                try file?.write(contentsOf: bytes)
            }
        }
    #else
        static var enabled: Bool { false }
        static func record(_: String, owner _: String = "stateless", input _: [String: Any], actual _: [String: Any]) {}
    #endif
}
