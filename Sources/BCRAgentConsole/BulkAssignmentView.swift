import BCRAgentCore
import SwiftUI

struct BulkAssignmentSection: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var section = BCRSection.encoder
    @State private var row = 1
    @State private var group = ""
    @State private var preview: BulkPreviewPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(L10n.text("批量分配"), icon: "rectangle.grid.1x2")
            Picker(L10n.text("控件区"), selection: $section) {
                ForEach(BCRSection.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker(L10n.text("组 / 行"), selection: $row) {
                ForEach(Array(section.rowRange), id: \.self) { Text(String($0)).tag($0) }
            }
            Picker(L10n.text("参数组"), selection: $group) {
                ForEach(model.configuration.parameterGroups, id: \.self) {
                    Text($0.isEmpty ? L10n.text("未分组") : $0).tag($0)
                }
            }
            Button(L10n.text("预览批量分配…")) {
                if let plan = model.bulkAssignmentPlan(section: section, row: row, group: group) {
                    preview = BulkPreviewPresentation(plan: plan)
                }
            }
            .disabled(model.configuration.parameters.isEmpty)
            .help(L10n.text("预览整行与参数组的顺序绑定，确认后应用"))
        }
        .panelStyle()
        .onAppear { selectValidGroup() }
        .onChange(of: section) { _, _ in row = section.rowRange.lowerBound }
        .onChange(of: model.configuration.parameterGroups) { _, _ in selectValidGroup() }
        .sheet(item: $preview) { presentation in
            BulkAssignmentPreview(model: model, plan: presentation.plan)
        }
    }

    private func selectValidGroup() {
        if !model.configuration.parameterGroups
            .contains(group) { group = model.configuration.parameterGroups.first ?? "" }
    }
}

private struct BulkPreviewPresentation: Identifiable {
    let id = UUID()
    let plan: BulkAssignmentPlan
}

private struct BulkAssignmentPreview: View {
    @ObservedObject var model: ConsoleViewModel
    let plan: BulkAssignmentPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(L10n.text("确认批量分配"), icon: "rectangle.grid.1x2")
            Text(L10n.text("将按参数组的顺序绑定。已有分配会被替换，参数当前值与硬件映射保留。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.changes, id: \.proposed.control) { change in
                        HStack(alignment: .top) {
                            Text(change.proposed.control.shortName).font(.body.monospaced().bold()).frame(
                                width: 58,
                                alignment: .leading
                            )
                            Text(summary(change.previous)).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right")
                            Text(summary(change.proposed)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if plan.skippedParameters > 0 {
                Text(L10n.text("本行容量不足，分组末尾 \(plan.skippedParameters) 个参数不会分配。")).font(.caption)
                    .foregroundStyle(.orange)
            }
            if model.configuration != plan.base {
                Text(L10n.text("配置已改变，请关闭并重新预览。")).foregroundStyle(.orange)
            }
            HStack {
                Button(L10n.text("取消")) { dismiss() }
                Spacer()
                Button(L10n.text("确认分配"), role: .destructive) {
                    if model.applyBulkAssignment(plan) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.configuration != plan.base)
                .help(L10n.text("确认应用预览中的批量分配"))
            }
        }
        .padding(24)
        .frame(width: 650, height: 480)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func summary(_ assignment: ControlAssignment?) -> String {
        guard let assignment else { return L10n.text("未分配") }
        let configuration = plan.base
        let title: String
        switch assignment.target {
        case let .switchPage(id): title = configuration.pages.first(where: { $0.id == id })?.name ?? L10n.text("基础页面")
        case let .runMacro(id): title = configuration.macros.first(where: { $0.id == id })?.name ?? L10n.text("宏")
        case let .parameter(id): title = configuration.parameter(id)?.name ?? id.rawValue
        case let .agentPrimaryAction(slot): title = "Agent \(slot.rawValue)"
        case let .resetGroup(group): title = L10n.text("复位 \(group)")
        case let .stepParameter(id, step, _): title = L10n
            .text("\(configuration.parameter(id)?.name ?? id.rawValue) 步进 \(step)")
        case let .setParameter(id, value): title = "\(configuration.parameter(id)?.name ?? id.rawValue) = \(value)"
        case let .cycleParameter(id, values): title = L10n
            .text("\(configuration.parameter(id)?.name ?? id.rawValue) 循环 \(values.count) 项")
        }
        let inverted = assignment.inverted ? L10n.text(" · 反向") : ""
        let behavior = !assignment.control.isContinuous && assignment.target.parameterID != nil && !assignment.target
            .isTrigger
            ? " · \(assignment.buttonBehavior.displayName)" : ""
        return title + inverted + behavior
    }
}
