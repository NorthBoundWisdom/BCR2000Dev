import AppKit
import ObjectiveC.runtime

/// Presentation-only interception inside an explicitly offscreen test process.
/// SwiftUI owns the concrete NSApplication subclass, so Info.plist principal-class replacement is insufficient.
/// Install local overrides on that concrete class; no other process or ordinary launch is affected.
@MainActor
enum OffscreenActivationGuard {
    static func install(on applicationClass: AnyClass) -> Bool {
        let activate = NSSelectorFromString("activate")
        let ignoring = NSSelectorFromString("activateIgnoringOtherApps:")
        guard let activationMethod = class_getInstanceMethod(applicationClass, activate),
              let ignoringMethod = class_getInstanceMethod(applicationClass, ignoring) else { return false }
        let noActivation: @convention(block) (AnyObject) -> Void = { _ in
            FileHandle.standardError.write(Data("bcr.offscreen_activation_suppressed: activate\n".utf8))
        }
        let noIgnoringActivation: @convention(block) (AnyObject, Bool) -> Void = { _, _ in
            FileHandle.standardError
                .write(Data("bcr.offscreen_activation_suppressed: activateIgnoringOtherApps\n".utf8))
        }
        class_replaceMethod(applicationClass, activate, imp_implementationWithBlock(noActivation),
                            method_getTypeEncoding(activationMethod))
        class_replaceMethod(applicationClass, ignoring, imp_implementationWithBlock(noIgnoringActivation),
                            method_getTypeEncoding(ignoringMethod))
        return true
    }
}
