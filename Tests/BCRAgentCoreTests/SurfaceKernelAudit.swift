import Foundation

/// Tests-only strict mismatch gate. Production contains no comparison or old algorithm.
/// Raw inputs/results are retained per process; any mismatch fails the verification run.
enum SurfaceKernelAudit {
    #if DEBUG
        private static let recorder = Recorder()
        static var enabled: Bool { recorder.enabled }
        static func compare(_ operation: String, owner: String = "stateless", input: [String: Any],
                            native: [String: Any], candidate: [String: Any], typedMatches: Bool = true)
        {
            guard recorder.enabled else { return }
            recorder.compare(operation, owner: owner, input: input, native: native, candidate: candidate,
                             typedMatches: typedMatches)
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
                let directory = URL(fileURLWithPath: path)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let target = directory.appendingPathComponent(
                        "operations-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).jsonl"
                    )
                    guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                        fatalError("Cannot create J3 shadow operation trace")
                    }
                    file = try FileHandle(forWritingTo: target)
                } catch { fatalError("Cannot open J3 shadow operation trace: \(error)") }
            }

            func compare(_ operation: String, owner: String, input: [String: Any],
                         native: [String: Any], candidate: [String: Any], typedMatches: Bool)
            {
                lock.lock(); defer { lock.unlock() }
                do {
                    let nativeBytes = try JSONSerialization.data(withJSONObject: native, options: [.sortedKeys])
                    let candidateBytes = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
                    var recordedInput = input
                    // Exact content-addressed catalogue records avoid repeating immutable
                    // binding tables. Decisions above compare actual typed values and full
                    // result bytes, never catalogue IDs or hashes. Every value is reconstructible.
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
                    let matches = typedMatches && nativeBytes == candidateBytes
                    let record: [String: Any] = ["sequence": sequence, "record_kind": "operation",
                                                 "operation": operation, "owner": owner,
                                                 "input": recordedInput, "native": native, "candidate": candidate,
                                                 "typed_matches": typedMatches, "matches": matches]
                    try write(record)
                    precondition(matches, "J3 independent runtime shadow mismatch in \(operation)")
                } catch { fatalError("Cannot write J3 shadow operation trace: \(error)") }
            }

            private func write(_ record: [String: Any]) throws {
                var bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                bytes.append(10)
                try file?.write(contentsOf: bytes)
            }
        }
    #else
        static var enabled: Bool { false }
        static func compare(_: String, owner _: String = "stateless", input _: [String: Any],
                            native _: [String: Any], candidate _: [String: Any], typedMatches _: Bool = true) {}
    #endif
}
