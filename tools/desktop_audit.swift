import AppKit
import Foundation

// Finite, read-only sampling for an explicitly scoped acceptance run. Never activates an app.
let args = CommandLine.arguments
if args.count != 3 || Int32(args[1]) == nil { exit(2) }
let parent = Int32(args[1])!
let directory = URL(fileURLWithPath: args[2], isDirectory: true)
let initial = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
var fronts = Set<pid_t>([initial])
var targets = Set<pid_t>()
var samples = 0
var maxWindows = 0
var visibleSamples = 0
var targetWasFront = false
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
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    fronts.insert(front)
    if targets.contains(front) {
        targetWasFront = true
        if stopped.insert(front).inserted { kill(front, SIGTERM) }
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
            if owner > 0, targets.contains(owner), stopped.insert(owner).inserted { kill(owner, SIGTERM) }
        }
    }
    samples += 1
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

let data = try JSONSerialization.data(withJSONObject: [
    "samples": samples, "frontmostPIDs": fronts.sorted(), "foregroundStable": fronts.count == 1,
    "targetPIDs": targets.sorted(), "targetWasFront": targetWasFront, "maxOwnedWindows": maxWindows,
    "visibleSamples": visibleSamples, "visibleWindows": visibleWindows
], options: [.prettyPrinted, .sortedKeys])
try data.write(to: directory.appending(path: "desktop-audit.json"), options: .atomic)
