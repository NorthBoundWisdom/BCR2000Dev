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
    FileHandle.standardError.write(Data("Usage: native_ui <pid> <exists|enabled|help|value|press> <identifier>\n".utf8))
    exit(2)
}

if arguments[2] == "snapshot" {
    guard UUID(uuidString: arguments[3]) != nil else { exit(2) }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("dev.bcragentconsole.integration.capture.\(arguments[1])"),
        object: arguments[3], userInfo: nil, deliverImmediately: true
    )
    exit(0)
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
    let matches: Bool
    if arguments[2] == "press-help" {
        matches = (attribute(element, kAXHelpAttribute) as? String)?.hasPrefix(arguments[3]) == true
    } else if arguments[2] == "press-description" || arguments[2] == "enabled-description" {
        matches = (attribute(element, kAXDescriptionAttribute) as? String)?.hasPrefix(arguments[3]) == true
    } else {
        matches = attribute(element, kAXIdentifierAttribute) as? String == arguments[3]
    }
    if matches {
        switch arguments[2] {
        case "exists": print("found"); exit(0)
        case "value":
            guard let value = attribute(element, kAXValueAttribute) as? String
                ?? attribute(element, kAXValueDescriptionAttribute) as? String
            else {
                let role = attribute(element, kAXRoleAttribute) as? String ?? "unknown"
                let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
                FileHandle.standardError
                    .write(Data("String value missing for \(arguments[3]); role=\(role); description=\(description)\n"
                            .utf8))
                exit(4)
            }
            print(value); exit(0)
        case "help":
            guard let help = attribute(element, kAXHelpAttribute) as? String else {
                FileHandle.standardError.write(Data("Help attribute missing for \(arguments[3])\n".utf8))
                exit(4)
            }
            print(help); exit(0)
        case "enabled", "enabled-description":
            if attribute(element, kAXEnabledAttribute) as? Bool == false { exit(3) }
            print("enabled"); exit(0)
        case "press", "press-help", "press-description":
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
