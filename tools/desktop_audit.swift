import AppKit
import ApplicationServices
import Foundation

// Finite, read-only sampling for an explicitly scoped acceptance run. Never activates an app.
let args = CommandLine.arguments
if args.count != 3 || Int32(args[1]) == nil { exit(2) }
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

let initial = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
var fronts = Set<pid_t>([initial])
var targets = Set<pid_t>()
var samples = 0
var maxWindows = 0
var visibleSamples = 0
let systemAccessibility = AXUIElementCreateSystemWide()
var focusedPIDs = Set<pid_t>()
var focusedTargetSamples = 0
var focusReadFailures = 0
var targetWasFront = false
var frontEvents: [[String: Any]] = []
var lastFront = initial
var visibleWindows: [[String: Any]] = []
var stopped = Set<pid_t>()
var displayCount: UInt32 = 0
CGGetActiveDisplayList(0, nil, &displayCount)
var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
let displays = displayIDs.map { CGDisplayBounds($0) }
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
        if stopped.insert(front).inserted { kill(front, SIGKILL) }
    }
    var focused: CFTypeRef?
    if AXUIElementCopyAttributeValue(systemAccessibility, kAXFocusedApplicationAttribute as CFString, &focused) ==
        .success,
       let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    {
        let element = focused as! AXUIElement
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            focusedPIDs.insert(pid)
            if targets.contains(pid) {
                focusedTargetSamples += 1
                if stopped.insert(pid).inserted { kill(pid, SIGKILL) }
            }
        } else { focusReadFailures += 1 }
    } else { focusReadFailures += 1 }
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
            if owner > 0, targets.contains(owner), stopped.insert(owner).inserted { kill(owner, SIGKILL) }
        }
    }
    samples += 1
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

let data = try JSONSerialization.data(withJSONObject: [
    "focusedPIDs": focusedPIDs.sorted(), "focusedTargetSamples": focusedTargetSamples,
    "focusReadFailures": focusReadFailures,
    "samples": samples, "frontmostPIDs": fronts.sorted(), "foregroundStable": fronts.count == 1,
    "targetPIDs": targets.sorted(), "targetWasFront": targetWasFront, "frontEvents": frontEvents,
    "maxOwnedWindows": maxWindows,
    "visibleSamples": visibleSamples, "visibleWindows": visibleWindows
], options: [.prettyPrinted, .sortedKeys])
try data.write(to: directory.appending(path: "desktop-audit.json"), options: .atomic)
