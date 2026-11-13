import BCRFoundation
import BCRSurfaceDomain
import Foundation
import SwiftUI

struct PresetNumberConfirmation: Identifiable {
    let id = UUID()
    let route: PresetRestoreRoute
    let dump: Data
    let names: BCRPresetNames
}

struct PresetNumberConfirmationSheet: View {
    @ObservedObject var model: ConsoleViewModel
    let context: PresetNumberConfirmation
    private var selected: Int? { model.selectedPresetNumber }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("核对实机预设编号")).font(.title2.bold())
            Text(L10n.text("设备不直接报告当前编号。请查看实机屏幕并选择一致的编号；仅确认本次连接的显示，不写入设备。"))
                .fixedSize(horizontal: false, vertical: true)
            Text(context.names.temporaryName ?? "—").font(.headline)
            Text(L10n.text("实机屏幕编号")).font(.subheadline.bold())
            if selected == nil {
                Text(L10n.text("请选择实机显示的编号")).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(context.names.candidates, id: \.self) { number in
                        Button { model.selectDisplayPresetNumber(context.id, number: number) } label: {
                            HStack {
                                Image(systemName: selected == number ? "largecircle.fill.circle" : "circle")
                                Text(BCRDisplayModel.text(for: .preset(number))).monospaced()
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("preset.number.option.\(number)")
                        .accessibilityValue(selected == number ? L10n.text("已选中") : L10n.text("未选中"))
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: min(240, CGFloat(context.names.candidates.count) * 30 + 12))
            HStack {
                Button(L10n.text("取消")) { model.cancelPresetNumberConfirmation() }
                    .accessibilityIdentifier("preset.number.cancel")
                Spacer()
                Button(L10n.text("确认与实机一致")) {
                    if let selected { model.confirmDisplayPresetNumber(context.id, number: selected) }
                }
                .disabled(selected == nil)
                .accessibilityIdentifier("preset.number.confirm")
            }
        }
        .padding(24).frame(width: 480)
        .accessibilityIdentifier("preset.number.dialog")
    }
}
