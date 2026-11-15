import BCRFoundation
import BCRSurfaceDomain
import Foundation

// Debug builds only: a release provider must never be able to swap its device for a script.
#if DEBUG
    /// Test-only transport double. This type never opens CoreMIDI and cannot send to a device.
    @MainActor
    final class TestOnlyHardwareDevice: SurfaceDevice {
        var connection = MIDIConnectionSnapshot(
            connectedSource: "TEST ONLY input",
            connectedDestination: "TEST ONLY output",
            lastError: nil
        )
        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        private var task: Task<Void, Never>?
        private var sent: [[UInt8]] = []
        private let commands: URL
        private let report: URL
        private var consumed = 0

        init(commands: URL, report: URL) {
            self.commands = commands; self.report = report
            connection.connectedSourceID = 1; connection.connectedDestinationID = 2
        }

        func send(_ message: MIDIVoiceMessage) throws {
            sent.append(message.midi1Bytes)
            try writeReport()
        }

        private func writeReport() throws {
            try JSONSerialization.data(withJSONObject: ["artifact": "test-only-hardware-double", "sent": sent,
                                                        "consumed": consumed], options: [.sortedKeys]).write(
                to: report,
                options: .atomic
            )
        }

        func start() {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    do {
                        let steps = try JSONSerialization
                            .jsonObject(with: Data(contentsOf: commands)) as? [[String: Any]] ?? []
                        for step in steps.dropFirst(consumed) {
                            switch step["operation"] as? String {
                            case "input":
                                if let cc = step["cc"] as? UInt8, let value = step["value"] as? UInt8 {
                                    onMessages?([.controlChange(channel: 0, number: cc, value: value)])
                                }
                            case "disconnect": connection = MIDIConnectionSnapshot(); onConnection?(connection)
                            case "reconnect", "endpoint":
                                connection = MIDIConnectionSnapshot(
                                    connectedSource: "TEST ONLY input",
                                    connectedDestination: "TEST ONLY output",
                                    lastError: nil
                                )
                                connection.connectedSourceID = Int32(consumed + 10); connection
                                    .connectedDestinationID = Int32(consumed + 20)
                                onConnection?(connection)
                            default: break
                            }
                            consumed += 1
                        }
                        try writeReport()
                    } catch {
                    /* A partial local script write is retried as a read; no external mutation is replayed. */ }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }

        func stop() { task?.cancel(); task = nil }
    }
#endif
