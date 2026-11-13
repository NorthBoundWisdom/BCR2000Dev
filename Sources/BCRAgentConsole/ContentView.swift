import BCRAgentCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            if let persistence = model.persistenceNotice {
                NoticeBanner(notice: persistence, model: model, onDismiss: { model.clearPersistenceNotice() })
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
            if let notice = model.notice {
                NoticeBanner(notice: notice, model: model)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
            Divider()
            GeometryReader { proxy in
                let inspectorWidth = min(max(proxy.size.width * 0.26, 360), 420)
                HStack(spacing: 0) {
                    SurfaceArea(model: model)
                    Divider()
                    ControlInspectorView(model: model)
                        .frame(width: inspectorWidth)
                }
            }
        }
        .background(CodexApprovalPresentation(controller: model.codex))
        .background(Theme.background)
        // The header's first row occupies the title strip instead of leaving it empty.
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .offscreenSafeSheet(
            id: "presetAlignment",
            isPresented: Binding(get: { model.presetAlignment != nil }, set: { shown in
                if !shown { model.dismissPresetAlignment() }
            })
        ) {
            if let state = model.presetAlignment { PresetAlignmentSheet(model: model, state: state) }
        }
        .offscreenSafeSheet(id: "presetNumber", item: Binding(
            get: { model.pendingPresetNumberConfirmation },
            set: { if $0 == nil { model.cancelPresetNumberConfirmation() } }
        )) { context in PresetNumberConfirmationSheet(model: model, context: context) }
        .offscreenSafeSheet(
            id: "hardwareConnection",
            item: Binding(get: { model.pendingHardwareConnection }, set: { value in
                if value == nil,
                   let prompt = model.pendingHardwareConnection { model.declineHardwareConnection(prompt.id) }
            })
        ) { prompt in
            HardwareConnectionSheet(prompt: prompt, model: model)
        }
    }
}

/// Chooses the panel scale and arrangement for the space left of the inspector.
///
/// - Side by side: the workspace sits right of the panel when at least `minWorkspace` points
///   remain; the panel grows up to the available height.
/// - Stacked: the workspace sits below; the panel grows with width but leaves `peek` points of
///   the workspace visible.
/// Either way the content is centered and only scrolls horizontally below the natural width.
struct ConsoleLayout: Equatable {
    static let padding: CGFloat = 18
    static let gap: CGFloat = 16
    static let minWorkspace: CGFloat = 400
    static let maxWorkspace: CGFloat = 720
    static let peek: CGFloat = 180

    let scale: CGFloat
    let isSideBySide: Bool
    let workspaceWidth: CGFloat

    var panelWidth: CGFloat {
        PanelMetrics.naturalSize.width * scale
    }

    var contentWidth: CGFloat {
        isSideBySide ? panelWidth + Self.gap + workspaceWidth : panelWidth
    }

    init(available: CGSize) {
        let natural = PanelMetrics.naturalSize
        let range = PanelMetrics.scaleRange
        let width = available.width - Self.padding * 2
        let height = available.height - Self.padding * 2
        func clamp(_ value: CGFloat) -> CGFloat {
            min(max(value, range.lowerBound), range.upperBound)
        }

        let sideScale = clamp(min((width - Self.gap - Self.minWorkspace) / natural.width, height / natural.height))
        let remaining = width - Self.gap - natural.width * sideScale
        if remaining >= Self.minWorkspace {
            scale = sideScale
            isSideBySide = true
            workspaceWidth = min(remaining, Self.maxWorkspace)
        } else {
            scale = clamp(min(width / natural.width, (height - Self.peek) / natural.height))
            isSideBySide = false
            workspaceWidth = natural.width * scale
        }
    }
}

private struct SurfaceArea: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        GeometryReader { proxy in
            let layout = ConsoleLayout(available: proxy.size)
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if layout.isSideBySide {
                        HStack(alignment: .top, spacing: ConsoleLayout.gap) {
                            SurfacePanelView(model: model)
                            WorkspaceTabsView(model: model)
                                .frame(width: layout.workspaceWidth)
                        }
                    } else {
                        VStack(spacing: ConsoleLayout.gap) {
                            SurfacePanelView(model: model)
                            WorkspaceTabsView(model: model)
                                .frame(width: layout.workspaceWidth)
                        }
                    }
                }
                .environment(\.panelMetrics, PanelMetrics(scale: layout.scale))
                .padding(ConsoleLayout.padding)
                // Centered whenever the window is wider than the content.
                .frame(minWidth: proxy.size.width, alignment: .top)
            }
        }
    }
}

/// Two tight rows: the product and configuration name share the window's title strip with the
/// traffic lights; every interactive control sits in a single row below it, outside the strip, so
/// window dragging and double-click zoom keep working.
private struct HeaderBar: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("BCR CONSOLE")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                Text(BuiltInNamePresentation.displayName(model.configuration.name))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.trafficLightInset - ConsoleLayout.padding)
            .frame(height: Theme.titleStripHeight)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)

            HStack(spacing: 10) {
                Picker(L10n.text("设备"), selection: Binding(get: { model.source }, set: { model.requestSource($0) })) {
                    ForEach(DeviceSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if let target = model.engine.learnTarget {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                            .symbolEffect(.pulse)
                        Text(L10n.text("学习中：请操作实体 \(target.shortName)"))
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Button(L10n.text("停止")) { model.stopLearning() }
                            .controlSize(.mini)
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.learn)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.learn.opacity(0.12), in: Capsule())
                }

                Spacer(minLength: 8)

                OutputStatusButton(controller: model.output)
                MCPStatusButton(controller: model.mcp)
                DeviceStatus(model: model)

                Divider().frame(height: 16)

                Toggle(L10n.text("跟随触碰"), isOn: $model.followsTouch)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .fixedSize()
                    .help(L10n.text("操作设备上的控件时自动在检查器中选中它"))

                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("设置"))
                .accessibilityLabel(L10n.text("设置"))
                .accessibilityIdentifier("app.settings")
            }
        }
        .padding(.horizontal, ConsoleLayout.padding)
        .padding(.bottom, 10)
    }
}

private struct DeviceStatus: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        let (title, detail, color, icon) = status
        SettingsChipButton(tab: .device) {
            StatusChip(title: title, icon: icon, tint: color, detail: detail)
        }
        .accessibilityLabel(L10n.text("MIDI 端口设置：\(title)"))
        .help(L10n.text("选择实体 MIDI 输入与输出端口") + "\n" + detail)
    }

    private var status: (String, String, Color, String) {
        if model.startingMIDI {
            return (L10n.text("MIDI 正在启动"), L10n.text("界面可继续使用，请等待设备就绪。"), .cyan, "hourglass")
        }
        let hardware = model.connection.isConnected
            ? "\(model.connection.connectedSource ?? "—") → \(model.connection.connectedDestination ?? "—")"
            : (model.connection.lastError ?? L10n.text("未找到 BCR2000 Port 1（建议 USB 模式 U-1）"))
        switch model.source {
        case .mock:
            return (
                L10n.text("Mock 设备运行中"),
                L10n.text("收 \(model.mock.receivedCount) · 发 \(model.mock.sentCount) · 实体：\(hardware)"),
                Theme.parameter,
                "cpu"
            )
        case .hardware:
            let dropped = model.droppedFeedbackCount > 0 ? L10n.text(" · \(model.droppedFeedbackCount) 条反馈未发送") : ""
            return (
                model.connection.isConnected ? L10n.text("BCR2000 已连接") : L10n.text("BCR2000 未连接"),
                hardware + dropped,
                model.connection.isConnected ? .green : .orange,
                model.connection.isConnected ? "cable.connector.horizontal" : "cable.connector.slash"
            )
        }
    }
}

private struct NoticeBanner: View {
    let notice: ConsoleNotice
    @ObservedObject var model: ConsoleViewModel
    var onDismiss: (() -> Void)? = nil

    private var color: Color {
        switch notice.level {
        case .info: .cyan
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.level == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(notice.text)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(notice.text)
            Spacer()
            if notice.action == .switchToHardware {
                Button(L10n.text("切换到实体")) { model.performNoticeAction(.switchToHardware) }
                    .controlSize(.small)
            }
            if notice.action == .saveMigration {
                Button(L10n.text("保存升级")) { model.performNoticeAction(.saveMigration) }
                    .controlSize(.small)
                    .help(L10n.text("把升级后的内容写回文件；原文件会先原样备份在同一目录。保存后此提示不再出现。"))
            }
            if notice.action == .retryConfigurationSave {
                Button(L10n.text("重试保存")) { model.performNoticeAction(.retryConfigurationSave) }
                    .controlSize(.small)
            }
            Button {
                if let onDismiss { onDismiss() } else { model.clearNotice() }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: Theme.insetRadius))
        .overlay { RoundedRectangle(cornerRadius: Theme.insetRadius).stroke(color.opacity(0.25)) }
    }
}
