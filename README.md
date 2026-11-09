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

## 控制台结构（2026-11 重构）

- **BCR2000 虚拟面板**：按真实面板布局显示 108 个控件（推钮编码器 4 组、2 行按键、
  3 行编码器、4 个用户按键），LED 灯环即软件回写值。
- **设备源切换**：`Mock 设备` 下面板就是模拟硬件；`实体 BCR2000` 下面板是镜像，
  操作即软件修改并回写硬件。
- **检查器**：查看/学习控件的 MIDI 身份，给控件分配参数、Agent 主操作或复位参数组，
  直接编辑参数名称、单位、范围和默认值。
- **工作区**：参数滑块（与硬件双向同步）、机械臂示意预览、Agent 槽位、MIDI 监视。
- **自适应布局**：放大窗口时面板等比放大并居中；空间足够时工作区移到面板右侧。
- 默认载入“机械臂示例”：P1-1…P1-8 = J1–J6、夹爪、速度；B1 行 = Agent 1–8；
  B2-1 = 使能；B2-8 = 复位机械臂。

`SurfaceSession` 在 Core 中统一执行效果、设备路由、学习、反馈丢弃计数与 MIDI 日志；
`SurfaceDevice` 由 Mock 适配器和 App 层的 CoreMIDI 适配器实现。设备断线期间的反馈只计数，
连接恢复时回写当前软件快照；Mock 模式下实体输入只记录。会话整合测试使用假设备，无需真机。
UI 保留选中项、跟随触碰与提示文案，Mock Agent 时间线通过会话层触发并回写 LED。
Agent 按键的当前 LED 反馈先于触发回调执行，确保同步更新后的状态在按住期间立即显示。

分层设计见 [控制器映射与反馈](docs/CONTROL_MAP.md)。

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

窗口保留自定义无标题栏样式：拖动顶部空白区域移动窗口，双击放大/还原；
旋钮拖动和参数滑块保留各自的输入行为。面板阴影仅作用于机壳背景，避免窗口移动时
对整棵控件树进行昂贵的阴影合成。量测见 [窗口拖曳分析](docs/WINDOW_DRAG_ANALYSIS.md)。

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

## 步进、预设与批量分配

按键可配置参数步进（正负与越界循环）、指定值、按顺序循环预设。
检查器可为参数启用步长吸附；软件与设备输入使用同一量化规则，必要时校正来源灯环。
批量分配选择控件区/行和参数组，先看差异再确认；预览期间配置若变化则需重新预览。
当前配置格式 v3，读取旧版会显示迁移信息，保存前备份原版。

## 配置导入与导出

参数工作区可导入/导出版本化 JSON，文件仅包含参数定义与功能分配，不包含实体硬件映射、MCP 凭据或运行值。
导入先校验，确认替换后才保存并应用；失败时不替换当前配置。参数编辑草稿遇到同 ID 的外部修改时，
未编辑草稿自动刷新，已编辑草稿提示冲突并等待选择。学习中替换配置会明确提示学习已停止。

加载非法本地配置会保留原文件，另存内容指纹命名的备份并显示持续提示；备份失败不会覆盖原文件。
详见 [配置恢复规则](docs/CONTROL_MAP.md) 和 [WP4 验收记录](docs/WP4_HANDOFF.md)。

## 通用 MCP 控制接口

顶栏 MCP 设置可开启仅绑定 127.0.0.1 的 Streamable HTTP 服务，默认端口 8787、默认关闭。
Token 首次启用时生成并存入 Keychain；权限、逐参数 agentWritable、限速和调用记录可在 App 查看。
支持通用 MCP 2026-07-28，并兼容 2025-11-25 标准握手；不依赖某个厂商的客户端。

Agent 写入经过与滑块相同的会话管线，MIDI 监视器显示 AGENT；示例 arm.enabled 默认不可写。
使用设置中的通用 curl 连接命令，或设置本机 BCR_MCP_TOKEN 环境变量后运行
tools/mcp_smoke.py（现代版）及 tools/mcp_smoke.py --legacy（兼容版）。
协议、工具 schema、权限与验收细节见 [MCP 文档](docs/MCP.md)。

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
- [后续开发计划](ROADMAP.md)
- [开发规范](CONTRIBUTING.md)
- [外部开发任务说明（无真机阶段）](DEV_PROMPT.md)
- [后续开发 TODO](TODO.md)

下一里程碑是把 Mock adapter 扩展为官方 `codex app-server` adapter，并补齐安全审批、重连恢复和发布化，详见 [TODO](TODO.md)。
