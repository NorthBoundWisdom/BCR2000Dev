import ApplicationServices
import Foundation

// PID-scoped AX traversal is much faster than one Apple Event per nested SwiftUI element.
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

let arguments = CommandLine.arguments
if arguments.count != 4 || Int32(arguments[1]) == nil || Int32(arguments[1])! <= 0 {
    FileHandle.standardError.write(Data("Usage: native_ui <pid> <exists|press> <identifier>\n".utf8))
    exit(2)
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission is required for the invoking terminal/agent.\n".utf8))
    exit(2)
}

let app = AXUIElementCreateApplication(Int32(arguments[1])!)
AXUIElementSetMessagingTimeout(app, 2)
var pending = [app]
var visited = 0
while let element = pending.popLast(), visited < 10000 {
    visited += 1
    if attribute(element, kAXIdentifierAttribute) as? String == arguments[3] {
        switch arguments[2] {
        case "exists": print("found"); exit(0)
        case "press":
            guard attribute(element, kAXEnabledAttribute) as? Bool != false,
                  AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            else {
                FileHandle.standardError.write(Data("Cannot press \(arguments[3])\n".utf8)); exit(4)
            }
            print("pressed"); exit(0)
        default: exit(2)
        }
    }
    if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        pending.append(contentsOf: children.reversed())
    }
}

exit(3) // Identifier absent is distinct from permission/interaction errors.
