import BCRFoundation
import SwiftUI

struct OfflineCaptureView: View {
    @ObservedObject var controller: OfflineCaptureController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(L10n.text("导入录制…")) { controller.chooseFile() }
                    .accessibilityIdentifier("offline.import")
                Button(L10n.text("清空")) { controller.clear() }.disabled(controller.loaded == nil)
            }
            Text(L10n.text("只读导入；仅输入送入隔离 Mock。录制的输出只展示，不重发。"))
                .font(.caption).foregroundStyle(.secondary)
            if controller.isLoading { ProgressView() }
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let capture = controller.loaded {
                Text(controller.name ?? "").font(.headline)
                Text(capture.review.isComplete ? L10n.text("完整") : L10n.text("证据不足"))
                    .foregroundStyle(capture.review.isComplete ? .green : .orange)
                Text(L10n
                    .text(
                        "版本：\(capture.review.unsupportedVersions) · 时间倒退：\(capture.review.nonMonotonicTimestamps) · 无效时间：\(capture.review.invalidTimestamps)"
                    ))
                Text(L10n
                    .text(
                        "截断行：\(capture.review.truncatedLines) · 无法解析：\(capture.review.unparseableLines) · 序列错误：\(capture.review.sequenceErrors)"
                    ))
                Text(L10n.text("边界错误：\(capture.review.boundaryErrors) · 快照错误：\(capture.review.contextErrors)"))
                Text("SHA-256 " + capture.sha256).font(.caption2.monospaced()).textSelection(.enabled)
                if let replay = controller.replay {
                    HStack {
                        Button(L10n.text("步进")) { controller.step() }.disabled(controller.isPlaying || replay.isAtEnd)
                            .accessibilityIdentifier("offline.step")
                        Button(L10n.text("运行")) { controller.run() }.disabled(controller.isPlaying || replay.isAtEnd)
                            .accessibilityIdentifier("offline.run")
                        Button(L10n.text("暂停")) { controller.pause() }.disabled(!controller.isPlaying)
                            .accessibilityIdentifier("offline.pause")
                        Button(L10n.text("重置重播")) { controller.reset() }.accessibilityIdentifier("offline.reset")
                    }
                    Text(L10n
                        .text(
                            "位置 \(replay.cursor)/\(capture.events.count) · 输入 \(replay.inputsReplayed) · 已跳过输出 \(replay.recordedOutputsSkipped)"
                        ))
                    ForEach(replay.session.engine.configuration.parameters.prefix(8)) { parameter in
                        HStack {
                            Text(parameter.name); Spacer(); Text(parameter
                                .formatted(replay.session.engine.value(of: parameter.id) ?? parameter.defaultValue))
                        }
                    }
                }
                Divider()
                ForEach(Array(capture.events.suffix(40).enumerated()), id: \.offset) { _, event in
                    HStack {
                        Text("#\(event.sequence) " + (event.direction ?? "—")).font(.caption.monospaced())
                        Text(event.fields["message"]?.stringValue ?? event.fields["origin"]?.stringValue ?? "SysEx")
                            .font(.caption).lineLimit(1)
                    }
                }
            }
        }
        .controlSize(.small)
        .buttonStyle(EvidenceButtonStyle())
    }
}
