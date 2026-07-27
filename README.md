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
- FreeCM Config、Build、Run、Test、Package 工作流；
- 14 个领域、映射、状态机、双向 surface state 和 MIDI codec 单元测试。

## 快速开始

```bash
git submodule update --init --recursive
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

## FreeCM

仓库通过 `FreeCM/` 子模块接入 FreeCM。工作流清单位于
`configs/freecm.commands.jsonc`：

- Config：生成本地 `source_roots.lock.jsonc` 并验证 Swift Package；
- Build：生成 unsigned Debug/Release `.app`；
- Run：在终端内运行 `.app` 中的可执行文件；
- Test：运行全部 Swift 单元测试；
- Package：生成本地 unsigned Release ZIP。

本机可以给子模块配置本地 URL override，`.gitmodules` 仍保留正式远端，因此其他机器可
正常初始化。

## 验证

```bash
python3 -m compileall -q configs
python3 configs/source_roots.py status --format json
python3 configs/source_roots.py verify
python3 configs/macos_workflow.py test
python3 configs/macos_workflow.py build
git diff --check
```

## 文档

- [开发设计](docs/DEVELOPMENT_DESIGN.md)
- [控制器映射与反馈](docs/CONTROL_MAP.md)
- [Swift/Qt/Rust 选型 ADR](docs/adr/001-native-swift-mvp.md)
- [后续开发 TODO](TODO.md)

下一里程碑是把 Mock adapter 扩展为官方 `codex app-server` adapter，并补齐安全审批、重连恢复和发布化，详见 [TODO](TODO.md)。
