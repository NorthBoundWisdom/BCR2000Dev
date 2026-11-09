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
            SectionTitle("批量分配", icon: "rectangle.grid.1x2")
            Picker("控件区", selection: $section) {
                ForEach(BCRSection.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("组 / 行", selection: $row) {
                ForEach(Array(section.rowRange), id: \.self) { Text(String($0)).tag($0) }
            }
            Picker("参数组", selection: $group) {
                ForEach(model.configuration.parameterGroups, id: \.self) {
                    Text($0.isEmpty ? "未分组" : $0).tag($0)
                }
            }
            Button("预览批量分配…") {
                if let plan = model.bulkAssignmentPlan(section: section, row: row, group: group) {
                    preview = BulkPreviewPresentation(plan: plan)
                }
            }
            .disabled(model.configuration.parameters.isEmpty)
            .help("预览整行与参数组的顺序绑定，确认后应用")
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
        if !model.configuration.parameterGroups.contains(group) { group = model.configuration.parameterGroups.first ?? "" }
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
            SectionTitle("确认批量分配", icon: "rectangle.grid.1x2")
            Text("将按参数组的顺序绑定。已有分配会被替换，参数当前值与硬件映射保留。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.changes, id: \.proposed.control) { change in
                        HStack(alignment: .top) {
                            Text(change.proposed.control.shortName).font(.body.monospaced().bold()).frame(width: 58, alignment: .leading)
                            Text(summary(change.previous)).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right")
                            Text(summary(change.proposed)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if plan.skippedParameters > 0 {
                Text("本行容量不足，分组末尾 \(plan.skippedParameters) 个参数不会分配。").font(.caption).foregroundStyle(.orange)
            }
            if model.configuration != plan.base {
                Text("配置已改变，请关闭并重新预览。").foregroundStyle(.orange)
            }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("确认分配", role: .destructive) {
                    if model.applyBulkAssignment(plan) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.configuration != plan.base)
                .help("确认应用预览中的批量分配")
            }
        }
        .padding(24)
        .frame(width: 650, height: 480)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func summary(_ assignment: ControlAssignment?) -> String {
        guard let assignment else { return "未分配" }
        let configuration = plan.base
        let title: String
        switch assignment.target {
        case let .parameter(id): title = configuration.parameter(id)?.name ?? id.rawValue
        case let .agentPrimaryAction(slot): title = "Agent \(slot.rawValue)"
        case let .resetGroup(group): title = "复位 \(group)"
        case let .stepParameter(id, step, _): title = "\(configuration.parameter(id)?.name ?? id.rawValue) 步进 \(step)"
        case let .setParameter(id, value): title = "\(configuration.parameter(id)?.name ?? id.rawValue) = \(value)"
        case let .cycleParameter(id, values): title = "\(configuration.parameter(id)?.name ?? id.rawValue) 循环 \(values.count) 项"
        }
        let inverted = assignment.inverted ? " · 反向" : ""
        let behavior = !assignment.control.isContinuous && assignment.target.parameterID != nil && !assignment.target.isTrigger
            ? " · \(assignment.buttonBehavior.displayName)" : ""
        return title + inverted + behavior
    }
}
