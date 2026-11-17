import AppKit
import CryptoKit
import QuartzCore
import BCRFoundation
import BCRSurfaceDomain
import BCRMCPAdapter
import BCRHTTPTransport
import BCRProviderMCPAdapter
import SurfaceControlContracts
import Foundation
import Darwin

/// This controller is a port on the actual GUI session; it never constructs a value/session owner.
@MainActor
final class GUIVirtualSurfaceController {
    let surface: SurfaceSession
    let context: GUIVirtualContext
    let gateway: MCPApplicationGateway
    let server: MCPHTTPServer
    private let adapter: BCRSurfaceControlAdapter?
    private let providerID: String
    private let writer: GUIVirtualReadyWriter
    private var terminal = false, starting = false, active = false
    private var revision = 0, capturePending = false, imageCount = 0
    private var errors: [String] = []
    private var diagnostics: [String] = []
    private var finishResult: [String]?
    private var finishTask: Task<[String], Never>?
    private var parameterObserver: UUID?
    private let instanceID: String
    private var setupFailed = false
    private var capturingEvidence = false
    private var captureRequests = 0, captureRuns = 0
    var awaitPresentation: @MainActor () async -> Void = { await Task.yield() }
    private weak var attachedWindow: NSWindow?
    func attachWindow(_ window: NSWindow?) { attachedWindow = window }

    init(surface: SurfaceSession, context: GUIVirtualContext, providerID: String) {
        precondition(!surface.permitsHardwareSource && surface.source == .mock)
        self.surface = surface; self.context = context; self.providerID = providerID
        instanceID = "gui-" + context.identity
        gateway = MCPApplicationGateway(session: surface, permissions: .init(parameterWrite: true),
                                        includeBuiltInTools: false, includeAgent: false,
                                        includeDeviceAdministration: false)
        do {
            adapter = try SurfaceControlMCPModule.install(on: gateway,
                                                          instanceID: instanceID,
                                                          permissions: .init(
                                                              input: false,
                                                              feedback: true,
                                                              reset: false
                                                          ),
                                                          mode: .guiVirtual,
                                                          inputEventCapacity: context.options.inputCapacity)
        } catch { adapter = nil; setupFailed = true }
        server = MCPHTTPServer(router: MCPRouter(service: gateway), providerID: providerID, exposesConsoleSource: false)
        writer = context.readyWriter
        context.onDenied = { [weak self] in self?.revoke("denied_" + $0) }
        gateway.onChange = { [weak self] in self?.scheduleEvidence() }
        server.onChange = { [weak self] in self?.scheduleEvidence() }
        parameterObserver = surface.observeParameters { [weak self] _ in self?.scheduleEvidence() }
    }

    private func recordError(_ value: String) {
        if errors.last != value { if errors.count == 32 { errors.removeFirst() }; errors.append(value) }
    }

    private func recordDiagnostic(_ value: String) {
        if diagnostics
            .last != value { if diagnostics.count == 32 { diagnostics.removeFirst() }; diagnostics.append(value) }
    }

    func start() async throws {
        guard !terminal, !setupFailed, !context.hasCleanedUp else { throw GUIVirtualError.unavailable }
        guard !starting, !active else { return }
        starting = true; let captured = revision
        defer { starting = false }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while actualWindow == nil {
            guard !terminal, captured == revision,
                  ProcessInfo.processInfo.systemUptime < deadline else { throw GUIVirtualError.unavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !terminal, captured == revision else { throw GUIVirtualError.unavailable }
        let port = try await server.start(port: context.options.port, token: context.credentials.owner,
                                          surfaceClients: context.credentials, displayWriteLimit: 60)
        guard !terminal, captured == revision else { server.stop(); throw GUIVirtualError.unavailable }
        active = true
        let discovery = gateway.call("surface_control_discover")
        guard !discovery.isError else { revoke("discovery_failed"); throw GUIVirtualError.unavailable }
        try writeMapping(discovery.value)
        try captureEvidence()
        var ready = evidence().objectValue ?? [:]
        ready["event"] = .string("gui_virtual.ready")
        ready["url"] = .string("http://127.0.0.1:\(port)/mcp")
        ready["provider_id"] = .string(providerID)
        ready["surface_control"] = discovery.value
        ready["mapping_path"] = .string(context.directory.appending(path: "mapping.json").path)
        ready["evidence_directory"] = .string(context.directory.path)
        try await writer.write(.object(ready))
        guard !terminal, captured == revision else { throw GUIVirtualError.unavailable }
    }

    private var actualWindow: NSWindow? {
        attachedWindow.flatMap { $0.isVisible && $0.contentView != nil ? $0 : nil }
    }

    private func evidence() -> JSONValue {
        let snapshot = gateway
            .call("surface_control_snapshot", arguments: .object(["instance_id": .string(instanceID)])).value
        return .object([
            "gui_virtual_surface": .bool(true), "physical_evidence": .bool(false), "hardware_qualified": .bool(false),
            "pid": .number(Int(getpid())), "bundle_id": .string(Bundle.main.bundleIdentifier ?? ""),
            "canonical_session_id": .string(context.identity), "source": .string("simulation"),
            "canonical_source": .string(surface.source.rawValue), "terminal": .bool(terminal),
            "window_visible": .bool(actualWindow != nil), "instance_id": .string(instanceID),
            "canonical_parameters": .object(Dictionary(uniqueKeysWithValues: surface.engine.parameterValues.map { (
                $0.key.rawValue,
                .double($0.value)
            ) })),
            "actual_gui_displays": .object(Dictionary(uniqueKeysWithValues: BCRLayout.allControls.map {
                (BCRSurfaceControlAdapter.controlID($0), .number(Int(surface.mock.value(of: $0))))
            })),
            "surface_snapshot": snapshot,
            "construction_calls": .object(ConsoleConstructionAudit.counts.mapValues(JSONValue.number)),
            "native_factory_calls": .number(ConsoleConstructionAudit.counts["native_midi_factory", default: 0]),
            "keychain_factory_calls": .number(ConsoleConstructionAudit.counts["keychain_factory", default: 0]),
            "keychain_load_calls": .number(ConsoleConstructionAudit.counts["keychain_load", default: 0]),
            "midi_denied_attempts": .object(context.midi.attempts.mapValues(JSONValue.number)),
            "errors": .array(errors.map(JSONValue.string)), "diagnostics": .array(diagnostics.map(JSONValue.string)),
            "image_count": .number(imageCount),
            "capture_requests": .number(captureRequests), "capture_runs": .number(captureRuns),
            "mock_received_display_messages": .number(surface.mock.receivedCount),
            "mock_sent_gestures": .number(surface.mock.sentCount)
        ])
    }

    private func writeMapping(_ discovery: JSONValue) throws {
        guard let profile = discovery.value(for: "profile"),
              let controls = profile.value(for: "controls")?.arrayValue else { throw GUIVirtualError.evidence }
        let rings = controls.filter { $0.value(for: "feedback_kinds")?.arrayValue?.contains(.string("value")) == true }
        let indicators = controls
            .filter { $0.value(for: "feedback_kinds")?.arrayValue?.contains(.string("indicator")) == true }
        guard rings.count >= 6, indicators.count >= 3 else { throw GUIVirtualError.evidence }
        var targets: [JSONValue] = []
        for (index, control) in rings.prefix(6).enumerated() {
            let range = control.value(for: "feedback_range")!
            targets.append(.object(["control_id": control.value(for: "id")!, "kind": .string("value"),
                                    "field": .string("joint.\(index + 1)"), "rest": range.value(for: "minimum")!,
                                    "source_range": .array([.double(-Double.pi), .double(Double.pi)]),
                                    "output_range": .array([
                                        range.value(for: "minimum")!,
                                        range.value(for: "maximum")!
                                    ])]))
        }
        for (index, field) in ["phase", "fault", "fresh"].enumerated() {
            var target: [String: JSONValue] = [
                "control_id": indicators[index].value(for: "id")!,
                "kind": .string("indicator"),
                "field": .string(field),
                "rest": .string("off")
            ]
            if field == "phase" { target["equals"] = .number(1) }
            targets.append(.object(target))
        }
        try writeOwned(.object(["schema_version": .number(1), "profiles": .array([.object([
            "source": .string("simulation"), "profile_id": profile.value(for: "id")!,
            "profile_version": profile.value(for: "version")!, "targets": .array(targets)
        ])])]), name: "mapping.json")
    }

    private func writeOwned(_ value: JSONValue, name: String) throws {
        let data = Data((try value.jsonText + "\n").utf8)
        guard data.count <= 65536 else { throw GUIVirtualError.evidence }
        try context.writeEvidence(data, name: name)
    }

    private struct RenderSignature: Equatable {
        let configuration: UInt64
        let mapping: UInt64
        let values: [String: UInt8]
        let parameters: [ParameterID: Double]
    }

    private func renderSignature() -> RenderSignature {
        .init(configuration: surface.configurationRevision, mapping: surface.mappingContextRevision,
              values: Dictionary(uniqueKeysWithValues: BCRLayout.allControls.map {
                  (BCRSurfaceControlAdapter.controlID($0), surface.mock.value(of: $0))
              }), parameters: surface.engine.parameterValues)
    }

    private func afterNativeFrameCommit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(
                nil,
                CFRunLoopActivity.beforeWaiting.rawValue,
                false,
                CFIndex.max
            ) { _, _ in
                continuation.resume()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func scheduleEvidence() {
        guard active, !capturingEvidence, !capturePending, !terminal else { return }
        captureRequests = min(captureRequests, Int.max - 1) + 1
        capturePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.capturePending = false }
            // Coalesce one RPC frame's display writes before doing expensive diagnostic PNG work.
            // Rendering stays outside the write/ack path and never becomes input/state authority.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            // Wait for the actual GUI publisher and its native presentation commit, not a guessed delay.
            for _ in 0 ..< 8 {
                guard !self.terminal else { return }
                let wanted = self.renderSignature()
                await self.awaitPresentation()
                await self.afterNativeFrameCommit()
                guard !self.terminal else { return }
                guard self.renderSignature() == wanted else { continue }
                do { try self.captureEvidence() } catch { self.recordDiagnostic("gui_evidence_failed") }
                return
            }
        }
    }

    private func captureEvidence() throws {
        guard !capturingEvidence, let window = actualWindow,
              let view = window.contentView else { throw GUIVirtualError.evidence }
        capturingEvidence = true; defer { capturingEvidence = false }
        let began = ProcessInfo.processInfo.systemUptime
        let pixels = view.bounds.width * view.bounds.height * window.backingScaleFactor * window.backingScaleFactor
        guard pixels > 0, pixels <= 16777216 else { throw GUIVirtualError.evidence }
        view.needsLayout = true; view.layoutSubtreeIfNeeded(); view.displayIfNeeded(); CATransaction.flush()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw GUIVirtualError.evidence }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]),
              data.count <= 16777216 else { throw GUIVirtualError.evidence }
        captureRuns = min(captureRuns, Int.max - 1) + 1
        try context.writeEvidence(data, name: "gui-last.png")
        if imageCount < 16 {
            imageCount += 1
            try context.writeEvidence(data, name: "gui-frame-\(imageCount).png")
        }
        var sampled = evidence().objectValue ?? [:]
        sampled["sample"] = .object(["id": .number(captureRuns), "render_started_monotonic_s": .double(began),
                                     "snapshot_finished_monotonic_s": .double(ProcessInfo.processInfo.systemUptime),
                                     "image_file": .string("gui-last.png"),
                                     "image_sha256": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }
                                         .joined()),
                                     "sampling": .string(
                                         "same MainActor turn: actual window render then current GUI getters and contract snapshot"
                                     )])
        try writeOwned(.object(sampled), name: "gui-latest.json")
    }

    func revoke(_ reason: String) {
        guard !terminal else { return }
        terminal = true; revision += 1; active = false; server.stop()
        gateway.permissions = .init(parameterWrite: false)
        do { try adapter?.invalidateContext(reason: reason) } catch { recordError("context_rotation_failed") }
        do { try surface.clearSimulationDisplayFeedback() } catch { recordError("display_clear_failed") }
        recordDiagnostic(reason)
        do { try writeOwned(evidence(), name: "gui-latest.json") } catch { recordDiagnostic("gui_evidence_failed") }
    }

    func finish() async -> [String] {
        if let finishResult { return finishResult }
        if let finishTask { return await finishTask.value }
        let task = Task { @MainActor in await self.performFinish() }
        finishTask = task
        let result = await task.value
        finishTask = nil
        return result
    }

    private func performFinish() async -> [String] {
        fputs("gui_virtual.finish_enter\n", stderr)
        let before = evidence()
        fputs("gui_virtual.finish_snapshot\n", stderr)
        if !terminal {
            terminal = true; revision += 1; active = false; server.stop()
            do { try adapter?.invalidateContext(reason: "gui_shutdown") } catch {
                recordError("context_rotation_failed")
            }
            do { try surface.clearSimulationDisplayFeedback() } catch { recordError("display_clear_failed") }
        }
        if let parameterObserver { surface.removeParameterObserver(parameterObserver); self.parameterObserver = nil }
        fputs("gui_virtual.finish_listener_stopped\n", stderr)
        let cleanup = context.cleanup()
        fputs("gui_virtual.finish_owned_cleaned\n", stderr)
        for error in cleanup { recordError(error) }
        do { try await writer.write(.object(["event": .string("gui_virtual.stopped"),
                                             "physical_evidence": .bool(false), "before_endpoint_stop": before,
                                             "cleanup_failed": .array(errors.map(JSONValue.string)),
                                             "diagnostics": .array(diagnostics.map(JSONValue.string)),
                                             "owned_cleanup": .array(cleanup.map(JSONValue.string))]))
        } catch { recordError("ready_pipe_write_failed") }
        fputs("gui_virtual.finish_record_written\n", stderr)
        writer.close()
        finishResult = errors
        return errors
    }
}

/// Two bounded records only; nonblocking owned pipe IO never stalls the MainActor.
final class GUIVirtualReadyWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bcr.gui-virtual-ready")
    private let fd: Int32
    private let lock = NSLock()
    private var records = 0, closed = false
    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }

    private func reserveRecord() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, records < 2 else { return false }
        records += 1; return true
    }

    func write(_ value: JSONValue) async throws {
        let data = Data((try value.jsonText + "\n").utf8)
        guard data.count <= 65536 else { throw GUIVirtualError.evidence }
        guard reserveRecord() else { throw GUIVirtualError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    var offset = 0
                    try data.withUnsafeBytes { bytes in
                        while offset < bytes.count {
                            self.lock.lock(); let closed = self.closed; self.lock.unlock()
                            guard !closed,
                                  ProcessInfo.processInfo.systemUptime < deadline
                            else { throw GUIVirtualError.invalidPipe }
                            let written = Darwin.write(
                                self.fd,
                                bytes.baseAddress!.advanced(by: offset),
                                bytes.count - offset
                            )
                            if written > 0 { offset += written; continue }
                            guard written < 0,
                                  errno == EAGAIN || errno == EINTR else { throw GUIVirtualError.invalidPipe }
                            var event = pollfd(fd: self.fd, events: Int16(POLLOUT), revents: 0)
                            _ = poll(&event, 1, 20)
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func close() {
        queue.sync {
            lock.lock(); let first = !closed; closed = true; lock.unlock()
            if first { Darwin.close(fd) }
        }
    }

    deinit { if !closed { Darwin.close(fd) } }
}
