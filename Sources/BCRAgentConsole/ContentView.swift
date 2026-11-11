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
                let inspectorWidth = min(max(proxy.size.width * 0.24, 330), 400)
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
        .preferredColorScheme(.dark)
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

private struct HeaderBar: View {
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BCR CONSOLE")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .tracking(1.6)
                    Text(model.configuration.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Picker(L10n.text("设备"), selection: Binding(get: { model.source }, set: { model.selectSource($0) })) {
                    ForEach(DeviceSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                Spacer()

                Toggle(L10n.text("跟随触碰"), isOn: $model.followsTouch)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(L10n.text("操作设备上的控件时自动在检查器中选中它"))

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help(L10n.text("设置"))
                .accessibilityLabel(L10n.text("设置"))
            }
            HStack(spacing: 16) {
                if let target = model.engine.learnTarget {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                            .symbolEffect(.pulse)
                        Text(L10n.text("学习中：请操作实体 \(target.shortName)"))
                            .font(.callout.bold())
                        Button(L10n.text("停止")) { model.stopLearning() }
                            .controlSize(.small)
                    }
                    .foregroundStyle(Theme.learn)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.learn.opacity(0.12), in: Capsule())
                }

                Spacer(minLength: 0)
                OutputStatusButton(controller: model.output)
                MCPStatusButton(controller: model.mcp)
                DeviceStatus(model: model)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

private struct DeviceStatus: View {
    @ObservedObject var model: ConsoleViewModel
    @State private var showsPorts = false

    var body: some View {
        let (title, detail, color, icon) = status
        Button { showsPorts = true } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.bold()).foregroundStyle(color)
                    Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 360, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("MIDI 端口设置：\(title)"))
        .help(L10n.text("选择实体 MIDI 输入与输出端口"))
        .sheet(isPresented: $showsPorts) { MIDIEndpointSettingsView(model: model) }
    }

    private var status: (String, String, Color, String) {
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
                .textSelection(.enabled)
            Spacer()
            if notice.action == .switchToHardware {
                Button(L10n.text("切换到实体")) { model.performNoticeAction(.switchToHardware) }
                    .controlSize(.small)
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
        .padding(10)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.25)) }
    }
}
