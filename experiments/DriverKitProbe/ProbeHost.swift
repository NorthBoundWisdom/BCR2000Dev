import AppKit
import AppIntents
import SystemExtensions

// A separate experiment host. Activation requires a button or explicit --activate.
@MainActor
final class ProbeHost: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private let status = NSTextField(wrappingLabelWithString: "尚未载入；扩展载入成功不代表 USB 输出已修复。")
    private var window: NSWindow?
    private let driverID = "dev.bcragentconsole.descriptorprobe.driver"
    private var action = "none"

    private func publish(_ phase: String, _ message: String) {
        status.stringValue = message
        guard let index = CommandLine.arguments.firstIndex(of: "--report"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        let path = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "phase": phase, "message": message, "action": action, "hardwareTested": false
            ], options: [.sortedKeys])
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            status.stringValue = "报告写入失败：\(error.localizedDescription)；\(message)"
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        let activateButton = NSButton(title: "载入测试扩展", target: self, action: #selector(activateDriver))
        let deactivate = NSButton(title: "移除测试扩展", target: self, action: #selector(deactivateDriver))
        let stack = NSStackView(views: [status, activateButton, deactivate])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 210),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "BCR DriverKit 可行性验证"
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--activate") { activate(confirm: false) }
        if CommandLine.arguments.contains("--deactivate") { deactivateDriver() }
    }

    @objc private func activateDriver() {
        activate(confirm: true)
    }

    private func activate(confirm: Bool) {
        let profile = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(driverID).dext/embedded.provisionprofile"
        )
        guard FileManager.default.fileExists(atPath: profile.path) else {
            publish("missing_profile", "缺少 DriverKit provisioning profile；不提交载入请求。")
            return
        }
        if confirm {
            let alert = NSAlert()
            alert.messageText = "载入当前打包的实验扩展？"
            alert.informativeText = "只用于已指定的 BCR2000。保持 SIP 与启动安全设置；若系统拒绝载入，记录错误后停止。"
            alert.addButton(withTitle: "载入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        action = "activate"
        submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: driverID, queue: .main))
    }

    @objc private func deactivateDriver() {
        action = "deactivate"
        submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: driverID, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        publish("submitted", "已提交系统请求，等待结果；尚未验证硬件。")
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
        Task { @MainActor in self.publish("needs_approval", "需要在系统设置授权；不要修改恢复模式或 SIP。") }
    }

    nonisolated func request(_: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = "系统请求失败：\(error.localizedDescription)"
        Task { @MainActor in self.publish("failed", message) }
    }

    nonisolated func request(_: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let message = "系统请求已结束（结果 \(result.rawValue)）；仍须独立验证 OUT 管道与身份回复。"
        Task { @MainActor in self.publish("finished_\(result.rawValue)", message) }
    }

    nonisolated func request(
        _: OSSystemExtensionRequest,
        actionForReplacingExtension _: OSSystemExtensionProperties,
        withExtension _: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Replacement follows button confirmation or an explicit --activate request.
        .replace
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

@main
struct ProbeApplication {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = ProbeHost()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
