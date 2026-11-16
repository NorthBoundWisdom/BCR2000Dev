import BCRFoundation
import SwiftUI

struct MonitorCaptureControls: View {
    @ObservedObject var capture: MonitorCaptureController
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(L10n.text("开始录制")) { capture.start() }
                    .disabled(!capture.canStart).accessibilityIdentifier("monitor.capture.start")
                Button(L10n.text("停止录制")) { capture.stop() }
                    .disabled(!capture.isRecording).accessibilityIdentifier("monitor.capture.stop")
                if capture.isRecording { Label(L10n.text("录制中"), systemImage: "record.circle") }
                if capture.phase == .stopping { Text(L10n.text("正在完成录制…")) }
            }
            .controlSize(.small)
            if let error = capture
                .error { Text(L10n.text("录制失败：\(error)")).foregroundStyle(.red).textSelection(.enabled) }
            if let url = capture.url {
                Text(url.path).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
