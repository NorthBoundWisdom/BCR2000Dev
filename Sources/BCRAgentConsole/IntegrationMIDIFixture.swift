#if DEBUG
    import BCRAgentCore
    import CryptoKit
    import Foundation

    /// Opt-in, in-memory device for native connection/alignment acceptance. Never opens CoreMIDI.
    @MainActor
    final class IntegrationMIDIFixture: MIDIService {
        private(set) var connection = MIDIConnectionSnapshot()
        private let startupDelay: Duration
        private let presetNumber: Int
        private let duplicateNames: Bool
        private let memory: [Int: Data]
        private var memoryReads = 0
        var onMessages: (@MainActor ([MIDIVoiceMessage]) -> Void)?
        var onConnection: (@MainActor (MIDIConnectionSnapshot) -> Void)?
        let supportsSnapshotReadback = true
        let supportsStartupConfiguration = true
        let hardwareMap: HardwareMap
        private let stateURL: URL
        private let original: Data
        private var preset: Data
        private var voiceWrites = 0
        private var presetWrites = 0
        private var reads = 0

        init(directory: URL, environment: [String: String] = [:]) throws {
            guard let delay = Int(environment["BCR_FIXTURE_STARTUP_DELAY_MS"] ?? "0"), (0 ... 60000).contains(delay),
                  let number = Int(environment["BCR_FIXTURE_PRESET_NUMBER"] ?? "8"), (1 ... 32).contains(number),
                  ["0", "1"].contains(environment["BCR_FIXTURE_DUPLICATE_NAMES"] ?? "0")
            else {
                throw ConfigurationFileError(reason: L10n.text("假设备启动参数无效"))
            }
            startupDelay = .milliseconds(delay)
            presetNumber = number
            duplicateNames = environment["BCR_FIXTURE_DUPLICATE_NAMES"] == "1"
            stateURL = directory.appending(path: "connection-fixture.json")
            var map = HardwareMap()
            var lines = ["$rev R1", "$preset", ".name 'UI Fixture'", ".egroups 4", ".fkeys on",
                         duplicateNames ? ".lock on" : ".lock off"]
            for number in 1 ... 56 {
                lines += ["$encoder \(number)", ".easypar CC 1 \(number) 0 127 absolute", ".mode 1dot"]
                let control: BCRControlID = number <= 32
                    ? .pushEncoder(group: (number - 1) / 8 + 1, (number - 1) % 8 + 1)
                    : .encoder(row: (number - 33) / 8 + 1, (number - 33) % 8 + 1)
                try map.bind(
                    control,
                    to: .init(kind: .controlChange, channel: 0, number: UInt8(number)),
                    ringMode: .oneDot
                )
            }
            hardwareMap = map
            func dump(_ lines: [String]) -> Data {
                Data((lines + ["$end"]).enumerated().flatMap { index, line in
                    [0xF0, 0, 0x20, 0x32, 0, 0x15, 0x20, UInt8(index >> 7), UInt8(index & 127)]
                        + Array(line.utf8) + [0xF7]
                })
            }
            let bytes = dump(lines)
            let other = dump(lines.map { $0 == ".fkeys on" ? ".fkeys off" : $0 })
            memory = Dictionary(uniqueKeysWithValues: (1 ... 32).map { ($0, $0 == number ? bytes : other) })
            original = bytes
            preset = bytes
            try record()
        }

        func start() throws {
            connection = MIDIConnectionSnapshot(connectedSource: "Fixture BCR2000 Port 1",
                                                connectedDestination: "Fixture BCR2000 Port 1")
            try record()
            onConnection?(connection)
        }

        func startWhenReady() async throws {
            try await Task.sleep(for: startupDelay)
            try start()
        }

        func selectEndpoints(_ selection: MIDIEndpointSelection) {}
        func send(_ message: MIDIVoiceMessage) throws { voiceWrites += 1; try record() }

        func readSnapshot(expected: Set<MIDIControlID>) async throws -> [MIDIVoiceMessage] {
            reads += 1; try record()
            try await Task.sleep(for: .milliseconds(200))
            return expected.map { MIDI1UMPCodec.feedback(control: $0, value: 40) }
        }

        func readPresetNames() async throws -> BCRPresetNames {
            reads += 1; try record()
            return BCRPresetNames(temporary: "UI Fixture", memory: (1 ... 32).map {
                ($0 == self.presetNumber || (self.duplicateNames && [1, 8].contains($0)))
                    ? "UI Fixture" : "Fixture \($0)"
            })
        }

        func readCurrentPreset() async throws -> Data {
            reads += 1; try record()
            try await Task.sleep(for: .milliseconds(200))
            return preset
        }

        func readMemoryPreset(_ number: Int) async throws -> Data {
            guard let dump = memory[number] else { throw MIDIStartupError.invalidProgram }
            reads += 1; memoryReads += 1; try record()
            try await Task.sleep(for: .milliseconds(200))
            return dump
        }

        func sendPresetFrames(_ frames: [[UInt8]], progress: @escaping @MainActor (Int) -> Void) async throws {
            presetWrites += 1; try record()
            try await Task.sleep(for: .milliseconds(400))
            for index in frames.indices {
                if index % 30 == 0 { try await Task.sleep(for: .milliseconds(20)) }
                progress(index + 1)
            }
            preset = Data(frames.joined())
            try record()
        }

        private func record() throws {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: [
                "fixture": true, "midiReady": connection.isConnected, "memoryReads": memoryReads,
                "voiceWrites": voiceWrites, "presetWrites": presetWrites, "reads": reads,
                "matchesOriginal": preset == original,
                "presetSHA256": SHA256.hash(data: preset).map { String(format: "%02x", $0) }.joined()
            ], options: [.sortedKeys])
            try data.write(to: stateURL, options: .atomic)
        }
    }
#endif
