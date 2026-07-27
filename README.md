# BCR Agent Console

用 Behringer BCR2000 作为双向实体控制器，在 macOS 上观察和控制 8 个 Agent 槽位。

首个 Swift MVP 已可运行：它会自动连接 BCR2000 Port 1，用快速学习绑定 8 个实体
CC/Note 按键，在 SwiftUI 与确定性 Mock Agent 之间共享同一状态机，并把状态值回写到
同一按键 LED 或编码器灯环。真实 Codex 接入不在本里程碑内。

## 已实现

- Swift 6、SwiftUI、macOS 14+；
- CoreMIDI 热插拔通知、BCR2000 端点发现及 Port 1 优先选择；
- MIDI 1.0 UMP 的 CC、Note On、Note Off 编解码；
- 8 槽位快速学习与本地持久化；
- 实体按键启动/中断/批准 Mock，UI 同步显示；
- `idle → queued → running → waitingApproval → completed` Mock 时间线；
- 每次状态变化向已学习控件发送 7-bit MIDI feedback；
- 独立“硬件镜像”页面，以 32 个 DAW 风格旋钮显示每个已发现 CC 的位置，并区分
  `IN` 设备值与 `OUT` 软件 feedback；
- Note On/Off 按键 pad、事件计数和实时 MIDI 事件面板；
- 输入去抖、短窗口 feedback echo 抑制和原始 MIDI 监视器；
- 应用图标、原生 `.app`、ZIP/DMG 打包、签名与公证工作流；
- 可选 FreeCM 插件 Config、Build、Run、Test、Package 接线；
- 领域、映射、状态机、双向 surface state、MIDI codec 与打包流程测试。

## 快速开始

```bash
python3 configs/setup_local_project.py
python3 configs/macos_workflow.py run
```

也可以直接打开生成的应用：

```bash
python3 configs/macos_workflow.py build
open build/app/BCRAgentConsole.app
```

`run` 会让应用进程归属当前终端，适合观察日志和用 `Ctrl+C` 停止；`open` 只适合日常使用。

## 第一次连接 BCR2000

1. 用 USB 连接 BCR2000。应用应显示
   `BCR2000 Port 1 → App → BCR2000 Port 1`。
2. 建议把 BCR2000 设为 USB 模式 U-1：同时按 `EDIT + STORE` 进入 Global Setup，
   用 Push Encoder 1 选择 `U-1`，按 `EXIT`。U-1 支持软件 parameter feedback。
3. 准备 8 个配置为 momentary 的 CC 或 Note 按键；按下值应为 64–127。
4. 在 Agent 控制台点击“开始 / 继续学习”，再按界面提示依次按下 8 个按键，分别绑定
   Agent 1–8。学习是显式开关，进入“硬件镜像”时会自动暂停，避免转旋钮时误绑定。
5. 再按映射后的实体键：
   空闲/终态时启动，运行/排队时中断，等待批准时批准。

切到“硬件镜像”后，转动任意旋钮即可看到按真实 MIDI 通道和 CC 编号排序的 32 旋钮
surface。青色 `IN` 是 BCR2000 发来的值，紫色 `OUT` 是应用回写的值；未触碰的控件保持
空位，不会假定当前 Preset 的固定编号。

映射保存在用户 Application Support 的
`BCRAgentConsole/controller-profile.json`，不会进入仓库。切换 BCR Preset 后如果消息编号
变化，请在界面选择“重置映射”并重新学习。

## 打包与 FreeCM 插件

构建无需 FreeCM 仓库、Python 安装包或子模块。版本默认值在 `configs/app_build.json`，
本机环境及签名设置放在被 Git 忽略的 `build.local.json`；Config 仅在缺失时创建它。

```bash
# Release：为当前机器架构生成 ad-hoc 签名的 DMG + ZIP、SHA-256 校验和与构建记录
python3 configs/macos_workflow.py package

# 同时支持 Apple Silicon 和 Intel 的 Universal 安装包
python3 configs/macos_workflow.py package --architecture universal
```

产物位于 `build/package/`。DMG 内有应用及 Applications 快捷方式。
Developer ID 签名、公证、最终安装包检查和 CI 发布参见 [打包指南](docs/PACKAGING.md)。
默认 ad-hoc 产物未经 Apple 公证。

`configs/freecm.commands.jsonc` 保留可选 FreeCM 插件入口：Config 准备配置，Build 生成带
图标的签名 `.app`，Run 在终端运行，Test 执行 Swift 测试，Package 默认生成 Release
DMG + ZIP，也提供单独 ZIP 和 Developer ID 公证选项。
`configs/source_root_workflow.py` 保留插件初始化、更新和构建清理入口。

## 验证

```bash
python3 -m compileall -q configs
python3 configs/validate_repo_commands.py .
python3 -m unittest discover -s Tests/BuildWorkflowTests -v
python3 configs/macos_workflow.py test
python3 configs/macos_workflow.py build
python3 configs/macos_workflow.py smoke
python3 configs/codex_schema.py generate  # 首次锁定/更新 schema 后执行
python3 configs/codex_schema.py verify
git diff --check
```

## 文档

- [开发设计](docs/DEVELOPMENT_DESIGN.md)
- [控制器映射与反馈](docs/CONTROL_MAP.md)
- [打包、签名与 CI 发布](docs/PACKAGING.md)
- [图标源文件与生成说明](assets/README.md)
- [Swift/Qt/Rust 选型 ADR](docs/adr/001-native-swift-mvp.md)
- [后续开发 TODO](TODO.md)

下一里程碑是把 Mock adapter 扩展为官方 `codex app-server` adapter，并补齐安全审批、重连恢复和发布化，详见 [TODO](TODO.md)。
