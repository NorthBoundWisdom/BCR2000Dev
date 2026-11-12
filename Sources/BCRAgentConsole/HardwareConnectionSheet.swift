import BCRAgentCore
import SwiftUI

struct HardwareConnectionSheet: View {
    let prompt: HardwareConnectionPrompt
    @ObservedObject var model: ConsoleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.text("连接 BCR2000"), systemImage: "cable.connector")
                .font(.title2.bold())
            Text(L10n.text("请选择同步方向。确认前，软件保持 Mock，不会改动设备。"))
                .foregroundStyle(.secondary)
            if let program = prompt.program {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("软件 → 硬件")).font(.headline)
                    Text(L10n.text("载入预设 \(program.preset)，切到分组 1，并把软件当前参数值写入控制器；不写永久预设存储。"))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("初始化并连接")) { model.connectHardware(prompt.id, mode: .initialize) }
                        .accessibilityIdentifier("connection.initialize")
                        .buttonStyle(.borderedProminent)
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading).panelStyle()
            }
            if prompt.canWrite {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("软件 → 硬件")).font(.headline)
                    Text(L10n.text("不切换预设，把软件当前参数值写入设备当前预设中已学习的控件。"))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("写入并连接")) { model.connectHardware(prompt.id, mode: .write) }
                        .accessibilityIdentifier("connection.write")
                        .buttonStyle(.bordered)
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading).panelStyle()
            }
            if prompt.canRead {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("硬件 → 软件")).font(.headline)
                    Text(L10n.text("读取控制器当前旋钮值，不切换预设或改动设备；分组在顶部输入后确认。"))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("按硬件现状连接")) { model.connectHardware(prompt.id, mode: .read) }
                        .accessibilityIdentifier("connection.read")
                        .buttonStyle(.bordered)
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading).panelStyle()
            }
            HStack {
                Spacer()
                Button(L10n.text("暂不连接")) { model.declineHardwareConnection(prompt.id) }
                    .accessibilityIdentifier("connection.decline")
                    .keyboardShortcut(.cancelAction)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection.dialog")
        .padding(24)
        .frame(width: 520)
    }
}
