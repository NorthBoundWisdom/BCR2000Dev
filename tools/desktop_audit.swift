import AppKit
import ApplicationServices
import Foundation

// Finite, read-only sampling for an explicitly scoped acceptance run. Never activates an app.
let args = CommandLine.arguments
if !(args.count == 3 || (args.count == 5 && args[3] == "--baseline-pid" && (Int32(args[4]) ?? -1) > 0)) ||
    Int32(args[1]) == nil { exit(2) }
let parent = Int32(args[1])!
let directory = URL(fileURLWithPath: args[2], isDirectory: true)
let bundle = try? String(contentsOf: directory.appending(path: "desktop-audit-bundle.txt"), encoding: .utf8)
let priorBundlePIDs = Set(bundle
    .map { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) } ?? [])
func isOffscreenSmoke(_ pid: pid_t) -> Bool {
    let command = Process()
    let output = Pipe()
    command.executableURL = URL(fileURLWithPath: "/bin/ps")
    command.arguments = ["-p", String(pid), "-o", "args="]
    command.standardOutput = output
    command.standardError = FileHandle.nullDevice
    do {
        try command.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isWhitespace })
        return text.contains("--startup-smoke") && text.contains("--offscreen")
    } catch { return false }
}

let accessibilityTrusted = AXIsProcessTrusted()
let systemAccessibility = AXUIElementCreateSystemWide()
@MainActor
func focusedApplicationPID() -> (pid: pid_t?, error: AXError) {
    var focused: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
        systemAccessibility, kAXFocusedApplicationAttribute as CFString, &focused
    )
    guard status == .success else { return (nil, status) }
    guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return (nil, .invalidUIElement) }
    var pid: pid_t = 0
    let result = AXUIElementGetPid(focused as! AXUIElement, &pid)
    return (result == .success ? pid : nil, result)
}

@MainActor
func desktopSnapshot() -> [String: Any] {
    let front = NSWorkspace.shared.frontmostApplication
    let focus = focusedApplicationPID()
    return [
        "accessibilityTrusted": accessibilityTrusted, "focusError": focus.error.rawValue,
        "focusedPID": focus.pid ?? -1, "frontmostPID": front?.processIdentifier ?? -1,
        "frontmostBundle": front?.bundleIdentifier ?? "unknown",
        "frontmostName": front?.localizedName ?? "unknown"
    ]
}

var displayCount: UInt32 = 0
CGGetActiveDisplayList(0, nil, &displayCount)
var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
let displays = displayIDs.map { CGDisplayBounds($0) }

if args.count == 5 {
    let baselinePID = Int32(args[4])!
    let deadline = Date().addingTimeInterval(6)
    var baseline: [String: Any] = [:]
    var ready = false
    repeat {
        // Establish/refresh the WindowServer connection before the AX read,
        // just as the ordinary sampler does between consecutive focus reads.
        _ = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
        baseline = desktopSnapshot()
        ready = baseline["focusedPID"] as? pid_t == baselinePID
            && baseline["frontmostPID"] as? pid_t == baselinePID
        if ready { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    let data = try JSONSerialization.data(withJSONObject: baseline, options: [.sortedKeys])
    try data.write(to: directory.appending(path: "desktop-preflight.json"), options: .atomic)
    guard ready else {
        FileHandle.standardError
            .write(Data("CI desktop has no verified keyboard-focus baseline for PID \(baselinePID): ".utf8))
        FileHandle.standardError.write(data)
        exit(2)
    }
}

let initialDesktop = desktopSnapshot()
let initial = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
var fronts = Set<pid_t>([initial])
var targets = Set<pid_t>()
var samples = 0
var maxWindows = 0
var visibleSamples = 0
var focusedPIDs = Set<pid_t>()
var focusedTargetSamples = 0
var focusReadFailures = 0
var focusErrors: [String: Int] = [:]
var targetWasFront = false
var frontEvents: [[String: Any]] = []
var lastFront = initial
var visibleWindows: [[String: Any]] = []
var stopped = Set<pid_t>()
let signalLog = directory.appending(path: "desktop-audit-signals.jsonl")
FileManager.default.createFile(atPath: signalLog.path, contents: nil)
let signalOutput = try FileHandle(forWritingTo: signalLog)
defer { try? signalOutput.close() }

func recordSignal(_ event: [String: Any]) {
    do {
        var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        data.append(0x0A)
        try signalOutput.write(contentsOf: data)
        try signalOutput.synchronize()
    } catch {
        FileHandle.standardError.write(Data("Could not persist desktop audit signal: \(error)\n".utf8))
        exit(2)
    }
}

@MainActor
func stopTarget(_ pid: pid_t, reason: String) {
    guard stopped.insert(pid).inserted else { return }
    let phase = (try? String(
        contentsOf: directory.appending(path: "lifecycle-phase.txt"),
        encoding: .utf8
    )) ?? "unknown"
    // Persist the sender/reason before SIGKILL can make the parent start cleanup.
    let event: [String: Any] = [
        "source": "desktop_audit", "senderPID": getpid(), "targetPID": pid,
        "signal": "SIGKILL", "reason": reason, "phase": phase,
        "time": Date().timeIntervalSince1970
    ]
    recordSignal(event.merging(["type": "signal-request"]) { _, new in new })
    let result = kill(pid, SIGKILL)
    let failure = result == 0 ? 0 : errno
    recordSignal(event.merging(["type": "signal-result", "result": result, "errno": failure]) { _, new in new })
}

try Data().write(to: directory.appending(path: "desktop-audit.ready"))
while !FileManager.default.fileExists(atPath: directory.appending(path: "desktop-audit.stop").path),
      kill(parent, 0) == 0
{
    if let text = try? String(contentsOf: directory.appending(path: "app-pid.txt"), encoding: .utf8),
       let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 { targets.insert(pid) }
    if let bundle {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            where !priorBundlePIDs.contains(app.processIdentifier) && !targets.contains(app.processIdentifier)
            && isOffscreenSmoke(app.processIdentifier)
        {
            targets.insert(app.processIdentifier)
        }
    }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    fronts.insert(front)
    if front != lastFront {
        let phase = (try? String(
            contentsOf: directory.appending(path: "lifecycle-phase.txt"),
            encoding: .utf8
        )) ?? "unknown"
        frontEvents.append(["pid": front, "phase": phase, "time": Date().timeIntervalSince1970])
        lastFront = front
    }
    if targets.contains(front) {
        targetWasFront = true
        stopTarget(front, reason: "target became frontmost")
    }
    let focus = focusedApplicationPID()
    if let pid = focus.pid {
        focusedPIDs.insert(pid)
        if targets.contains(pid) {
            focusedTargetSamples += 1
            stopTarget(pid, reason: "target received keyboard focus")
        }
    } else {
        focusReadFailures += 1
        focusErrors[String(focus.error.rawValue), default: 0] += 1
    }
    let windows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).filter {
        targets.contains(($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1)
    }
    maxWindows = max(maxWindows, windows.count)
    let visible = windows.filter {
        guard ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              ($0[kCGWindowIsOnscreen as String] as? Bool ?? false),
              let bounds = $0[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return displays.contains { $0.intersects(rect) }
    }
    if !visible.isEmpty {
        visibleSamples += 1
        for window in visible {
            let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            if visibleWindows.count < 10 {
                visibleWindows.append([
                    "pid": owner, "id": window[kCGWindowNumber as String] ?? -1,
                    "alpha": window[kCGWindowAlpha as String] ?? -1,
                    "bounds": window[kCGWindowBounds as String] ?? [:],
                    "layer": window[kCGWindowLayer as String] ?? -1
                ])
            }
            if owner > 0, targets.contains(owner) { stopTarget(owner, reason: "target displayed a visible window") }
        }
    }
    samples += 1
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

let data = try JSONSerialization.data(withJSONObject: [
    "focusedPIDs": focusedPIDs.sorted(), "focusedTargetSamples": focusedTargetSamples,
    "focusReadFailures": focusReadFailures,
    "focusErrors": focusErrors, "initialDesktop": initialDesktop,
    "samples": samples, "frontmostPIDs": fronts.sorted(), "foregroundStable": fronts.count == 1,
    "targetPIDs": targets.sorted(), "targetWasFront": targetWasFront, "frontEvents": frontEvents,
    "maxOwnedWindows": maxWindows,
    "visibleSamples": visibleSamples, "visibleWindows": visibleWindows
], options: [.prettyPrinted, .sortedKeys])
try data.write(to: directory.appending(path: "desktop-audit.json"), options: .atomic)
