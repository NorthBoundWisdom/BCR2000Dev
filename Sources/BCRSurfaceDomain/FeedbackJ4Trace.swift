import BCRFoundation
import Foundation

/// Debug-only, default-off observation. Core plan/check/receipt results are primary; this tap only observes copied values.
/// Scheduler arguments and native results are deliberately separate files; no result seeds a candidate.
enum FeedbackJ4Trace {
    #if DEBUG
        private static let recorder = Recorder()
        static var enabled: Bool { recorder.enabled }
        static func schedulerInput(
            owner: String,
            operation: String,
            context: Any = NSNull(),
            arguments: () -> [String: Any]
        ) -> Int? {
            guard enabled else { return nil }
            return recorder.input(owner: owner, operation: operation, arguments: arguments(), context: context)
        }

        static func sessionInput(owner: String, operation: String, arguments: () -> [String: Any]) -> UInt64? {
            guard enabled else { return nil }
            return recorder.sessionInput(owner: owner, operation: operation, arguments: arguments())
        }

        static func sessionOutput(owner: String, ordinal: UInt64?, output: () -> [String: Any]) {
            guard let ordinal, enabled else { return }
            recorder.sessionOutput(owner: owner, ordinal: ordinal, output: output())
        }

        static func schedulerOutput(owner: String, ordinal: Int?, output: () -> [String: Any]) {
            guard let ordinal, enabled else { return }
            recorder.output(owner: owner, ordinal: ordinal, output: output())
        }

        static func io(owner: String, event: MonitorEvent) {
            guard enabled else { return }
            recorder.io(owner: owner, event: event)
        }

        @discardableResult
        static func actual(
            owner: String,
            operation: String,
            input: @autoclosure () -> [String: Any],
            actual: @autoclosure () -> [String: Any]
        ) -> Int? {
            guard enabled else { return nil }
            return recorder.actual(owner: owner, operation: operation, input: input(), actual: actual())
        }

        private final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private let inputFile: FileHandle?, outputFile: FileHandle?, planFile: FileHandle?, ioFile: FileHandle?,
                        sessionFile: FileHandle?, sessionNativeFile: FileHandle?
            private var ordinals: [String: Int] = [:]
            private var planOrdinal = 0
            private var causalOrdinal = 0
            private var sessionOrdinals: [String: UInt64] = [:]
            var enabled: Bool { inputFile != nil }
            init() {
                guard let root = ProcessInfo.processInfo.environment["BCR_J4_SHADOW_ROOT"] else {
                    inputFile = nil; outputFile = nil; planFile = nil; ioFile = nil; sessionFile =
                        nil; sessionNativeFile = nil; return
                }
                do {
                    let directory = URL(fileURLWithPath: root)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    func open(_ family: String) throws -> FileHandle {
                        let path = directory
                            .appending(path: "\(family)-\(ProcessInfo.processInfo.processIdentifier).jsonl").path
                        let descriptor = path.withCString { openFile($0) }
                        guard descriptor >= 0 else { throw CocoaError(.fileWriteFileExists) }
                        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    }
                    inputFile = try open("scheduler-input"); outputFile = try open("scheduler-native"); planFile =
                        try open("feedback-actual"); ioFile = try open("native-io"); sessionFile =
                        try open("session-input"); sessionNativeFile = try open("session-native")
                } catch { fatalError("Cannot create fresh J4 raw trace: \(error)") }
            }

            func input(owner: String, operation: String, arguments: [String: Any], context: Any) -> Int {
                lock.lock(); defer { lock.unlock() }
                let ordinal = ordinals[owner, default: 0] + 1; ordinals[owner] = ordinal
                causalOrdinal += 1
                var context = context as? [String: Any] ?? ["native_context": context]
                context["causal_ordinal"] = String(causalOrdinal)
                write(["schema_version": 1, "owner": owner, "ordinal": String(ordinal), "operation": operation,
                       "arguments": arguments, "context": context], to: inputFile)
                return ordinal
            }

            func sessionInput(owner: String, operation: String, arguments: [String: Any]) -> UInt64 {
                lock.lock(); defer { lock.unlock() }
                let ordinal = sessionOrdinals[owner, default: 0] + 1; sessionOrdinals[owner] = ordinal
                causalOrdinal += 1
                write(["schema_version": 1, "owner": owner, "ordinal": String(ordinal), "operation": operation,
                       "arguments": arguments, "context": ["causal_ordinal": String(causalOrdinal)]], to: sessionFile)
                return ordinal
            }

            func sessionOutput(owner: String, ordinal: UInt64, output: [String: Any]) {
                lock.lock(); defer { lock.unlock() }
                write(
                    ["schema_version": 1, "owner": owner, "ordinal": String(ordinal), "output": output],
                    to: sessionNativeFile
                )
            }

            func output(owner: String, ordinal: Int, output: [String: Any]) {
                lock.lock(); defer { lock.unlock() }
                write(
                    ["schema_version": 1, "owner": owner, "ordinal": String(ordinal), "output": output],
                    to: outputFile
                )
            }

            func actual(owner: String, operation: String, input: [String: Any], actual: [String: Any]) -> Int {
                lock.lock(); defer { lock.unlock() }; planOrdinal += 1
                write(["schema_version": 1, "owner": owner, "ordinal": String(planOrdinal), "operation": operation,
                       "input": input, "actual": actual], to: planFile)
                return planOrdinal
            }

            func io(owner: String, event: MonitorEvent) {
                lock.lock(); defer { lock.unlock() }
                write(["schema_version": 1, "owner": owner, "id": String(event.id),
                       "time": event.time.timeIntervalSinceReferenceDate,
                       "monotonic_time": event.monotonicTime as Any? ?? NSNull(),
                       "direction": event.direction.rawValue, "source": event.source.rawValue,
                       "message": FeedbackJ4Trace.message(event.message),
                       "control": event.control.map(BCRKernelProjection.controlValue) as Any? ?? NSNull(),
                       "ignored": event.ignored, "origin": event.origin.rawValue,
                       "delivery": event.delivery?.rawValue as Any? ?? NSNull(),
                       "endpoint": FeedbackJ4Trace.endpoint(event.endpoint),
                       "context": FeedbackJ4Trace.context(event.context),
                       "input_press_mode": event.inputPressMode?.rawValue as Any? ?? NSNull()], to: ioFile)
            }

            private func write(_ value: [String: Any], to file: FileHandle?) {
                do {
                    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); bytes
                        .append(10)
                    try file?.write(contentsOf: bytes)
                } catch { fatalError("Cannot preserve complete J4 raw record: \(error)") }
            }
        }
    #else
        static var enabled: Bool { false }
        static func sessionInput(owner: String, operation: String, arguments: () -> [String: Any]) -> UInt64? { nil }
        static func sessionOutput(owner: String, ordinal: UInt64?, output: () -> [String: Any]) {}
        static func io(owner: String, event: MonitorEvent) {}
        static func schedulerInput(
            owner: String,
            operation: String,
            context: Any = NSNull(),
            arguments: () -> [String: Any]
        ) -> Int? { nil }
        static func schedulerOutput(owner: String, ordinal: Int?, output: () -> [String: Any]) {}
        @discardableResult
        static func actual(
            owner: String,
            operation: String,
            input: @autoclosure () -> [String: Any],
            actual: @autoclosure () -> [String: Any]
        ) -> Int? { nil }
    #endif
}

#if DEBUG
    #if os(Linux)
        import Glibc
    #else
        import Darwin
    #endif
    private func openFile(_ path: UnsafePointer<CChar>) -> Int32 { open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
#endif

extension FeedbackJ4Trace {
    static func reference(owner: String, ordinal: UInt64?) -> Any {
        ordinal.map { ["owner": owner, "ordinal": String($0)] } as Any? ?? NSNull()
    }

    static func hardwareMap(_ map: HardwareMap) -> Any {
        #if DEBUG
            guard enabled else { return NSNull() }
            return hardwareMapMemo.value(map)
        #else
            return NSNull()
        #endif
    }

    #if DEBUG
        private static let hardwareMapMemo = HardwareMapMemo()
        static var hardwareMapMemoStatistics: (hits: Int, misses: Int, entries: Int) {
            guard enabled else { return (0, 0, 0) }
            return hardwareMapMemo.statistics
        }

        private final class HardwareMapMemo: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Data: Any] = [:]
            private var hits = 0, misses = 0
            var statistics: (Int, Int, Int) { lock.withLock { (hits, misses, values.count) } }
            func value(_ map: HardwareMap) -> Any {
                // Whole original serialized bytes, never domain Equatable/hash-only identity.
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let bytes = try! encoder.encode(map)
                return lock.withLock {
                    if let value = values[bytes] { hits += 1; return value }
                    misses += 1
                    let value = try! JSONSerialization.jsonObject(with: bytes)
                    if values.count < 16 { values[bytes] = value }
                    return value
                }
            }
        }
    #endif

    static func policy(_ policy: FeedbackPolicy) -> [String: Any] {
        ["enabled": policy.enabled, "messages_per_second": policy.messagesPerSecond,
         "burst": policy.burst, "error_cooldown": policy.errorCooldown]
    }

    static func key(_ id: MIDIControlID) -> String { "\(id.kind.rawValue).\(id.channel).\(id.number)" }
    static func endpoint(_ value: MIDIEndpointSource?) -> Any {
        guard let value else { return NSNull() }
        return ["endpoint_id": value.endpointID, "device_id": value.deviceID as Any? ?? NSNull(),
                "connection_generation": String(value.connectionGeneration),
                "provenance": value.provenance.rawValue] as [String: Any]
    }

    static func connection(_ value: MIDIConnectionSnapshot) -> [String: Any] {
        func descriptors(_ values: [MIDIEndpointDescriptor]) -> [[String: Any]] {
            values.map { ["id": String($0.id), "name": $0.name, "availability_known": $0.availabilityKnown,
                          "provenance": $0.provenance.rawValue] }
        }
        return ["input_id": value.connectedSourceID.map(String.init) as Any? ?? NSNull(),
                "output_id": value.connectedDestinationID.map(String.init) as Any? ?? NSNull(),
                "transport_generation": value.transportGeneration.map(String.init) as Any? ?? NSNull(),
                "input_name": value.connectedSource as Any? ?? NSNull(),
                "output_name": value.connectedDestination as Any? ?? NSNull(),
                "input_names": value.sourceNames, "output_names": value.destinationNames,
                "input_endpoints": descriptors(value.sourceEndpoints),
                "output_endpoints": descriptors(value.destinationEndpoints),
                "last_error": value.lastError as Any? ?? NSNull(), "is_connected": value.isConnected]
    }

    static func context(_ value: SurfaceEventContext?) -> Any {
        guard let value else { return NSNull() }
        return ["generation": value.generation, "mapping_generation": String(value.mappingGeneration),
                "known_device_context_id": value.knownDeviceContextID as Any? ?? NSNull()] as [String: Any]
    }

    static func scope(_ item: ScheduledFeedback) -> [String: Any] {
        ["origin": item.origin.rawValue, "source": item.source?.rawValue as Any? ?? NSNull(),
         "endpoint": endpoint(item.endpoint),
         "mapping_revision": item.mappingRevision.map(String.init) as Any? ?? NSNull(),
         "context": context(item.context)]
    }

    static func message(_ value: MIDIVoiceMessage) -> [String: Any] {
        switch value {
        case let .controlChange(channel, number, value):
            ["case": "controlChange", "channel": Int(channel), "number": Int(number), "value": Int(value)]
        case let .nrpn(channel, number, value):
            ["case": "nrpn", "channel": Int(channel), "number": Int(number), "value": Int(value)]
        case let .noteOn(channel, number, value):
            ["case": "noteOn", "channel": Int(channel), "number": Int(number), "value": Int(value)]
        case let .noteOff(channel, number, value):
            ["case": "noteOff", "channel": Int(channel), "number": Int(number), "value": Int(value)]
        }
    }

    static func scheduled(_ item: ScheduledFeedback) -> [String: Any] {
        var result = scope(item)
        result["message"] = message(item.message)
        return result
    }

    static func entry(_ item: ScheduledFeedback) -> [String: Any] {
        ["key": key(item.message.controlID), "value": scheduled(item), "scope": scope(item)]
    }
}
