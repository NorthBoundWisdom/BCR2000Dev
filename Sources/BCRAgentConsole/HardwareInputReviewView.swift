import BCRFoundation
import BCRSurfaceDomain
import SwiftUI

struct HardwareInputReviewView: View {
    @ObservedObject var controller: InputReviewController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("观察来源"))
                Button { controller.source = .hardware } label: {
                    Label(
                        L10n.text("实体输入"),
                        systemImage: controller.source == .hardware ? "checkmark.circle.fill" : "circle"
                    )
                }.accessibilityIdentifier("inputReview.scope.hardware")
                Button { controller.source = .mock } label: {
                    Label(
                        L10n.text("Mock 输入"),
                        systemImage: controller.source == .mock ? "checkmark.circle.fill" : "circle"
                    )
                }.accessibilityIdentifier("inputReview.scope.mock")
            }
            Text(L10n.text("只观察，不发送、不学习、不改映射；覆盖记录不是硬件验收结论。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(L10n
                    .text(
                        "已观察 \(controller.review.observedControlCount)/108 · 消息 \(controller.review.messageCount) · 未映射 \(controller.review.unmappedMessageCount) · 回声 \(controller.review.echoCount)"
                    ))
                Spacer()
                Button(L10n.text("导出审查…")) { controller.chooseExport() }.disabled(controller.isExporting)
                    .accessibilityIdentifier("inputReview.export")
            }
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let receipt = controller
                .receipt { Text("SHA-256 " + receipt.sha256).font(.caption2.monospaced()).textSelection(.enabled) }
            ForEach(BCRSection.allCases, id: \.self) { section in
                ForEach(Array(section.rowRange), id: \.self) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.displayName + " · \(row)").font(.subheadline.bold())
                        ForEach(BCRLayout.allControls.filter { $0.section == section && $0.row == row }) { control in
                            let review = controller.review.review(control)
                            HStack(spacing: 8) {
                                Text(control.shortName).font(.caption.monospaced()).frame(
                                    width: 48,
                                    alignment: .leading
                                )
                                Label(
                                    status(review, control: control),
                                    systemImage: review.eventCount == 0 ? "minus.circle" : "checkmark.circle"
                                )
                                .frame(width: 110, alignment: .leading)
                                Text(review.lastIdentity?.description ?? "—").font(.caption.monospaced())
                                Spacer()
                                Text(review.latestValue.map(String.init) ?? "—").font(.caption.monospaced())
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .insetCard()
                }
            }
        }
        .controlSize(.small)
        .buttonStyle(EvidenceButtonStyle())
    }

    private func status(_ review: ControlInputReview, control: BCRControlID) -> String {
        guard review.eventCount > 0 else { return L10n.text("未观察") }
        return review.matches(controller.map.midi(for: control)) == true ? L10n.text("匹配映射") : L10n.text("映射不一致")
    }
}
