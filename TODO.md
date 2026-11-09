# BCR2000 Agent Console 开发 TODO

> 阶段目标与验收标准见 [ROADMAP.md](ROADMAP.md)，开发与提交规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

状态（截至 2026-11-09）：WP1、WP3–WP7 已在 Mock 下完成；WP3–WP7 审查发现的问题正在修复，
修复前不推送。实体 BCR2000 已连接，CoreMIDI 可见 `BCR2000 Port 1/2`（输入）与
`BCR2000 Port 1/2/3`（输出），R1 实机验证解除阻塞。

执行顺序：A 审查修正 → 推送 → B 实机验证（HW0–HW6）→ C 按实测结果修正 → D 设计改进与 WP2 → E 远期。

## A. WP3–WP7 审查修正（进行中，修完后一起推送）

审查基线 `aa6e180..ef57989`：186 条 Swift 测试、19 条 BuildWorkflowTests、6 条仿真测试、
隔离原生 MCP 两版协议验收通过；以下问题必须修复后再推送。

- [ ] A1【高】MCP 配置写入不得削弱参数保护：拒绝通过 MCP 修改 `agentWritable`，拒绝修改不可写参数
  和输出使能参数的定义（范围、类型、默认值）。回归测试覆盖：翻转 `agentWritable` 后写入、
  `minimum:-1, maximum:0` 把当前值变为“开”、默认值改为 1。
- [ ] A2【高】启动或恢复输出时不得因使能已开而直接运动：开始输出后必须先观察到使能“关 → 开”
  才放行；评估启动时是否不自动恢复输出。测试覆盖 `restore()` 与使能默认值为开。
- [ ] A3【中】MCP `reset_group` 遇到不可写参数时整组失败（示例“机械臂”组必现）：
  跳过不可写参数并在结果中列出，其余仍原子写入。
- [ ] A4【中低】`ArmPreviewView` 用 `Int(...)` 转换角度，超大值会让 App 崩溃：改为有界格式化，补测试。
- [ ] A5【低】`Tests/BCRAgentCoreTests/PersistenceValidationTests.swift` 末尾空行导致
  `git diff --check` 失败；交接中的检查需改为针对提交范围（`git diff --check <base>..HEAD`）。
- [ ] A6 修复后复跑全部检查与 `tools/mcp_integration.py`，然后与 WP3–WP7 一起推送 `origin/main`。

## B. 实机验证（R1，现在可做）

规则：只在 Mock 关闭、实体模式下进行；不连接真实机械臂（OSC 只连 `tools/arm_sim.py`）；
App 不发送 SysEx、不改写设备 Preset，开始前用 BC Manager 等工具备份当前 Preset。
学到的映射只存在 Application Support，不进 git；结论（不含个人 Preset 原始导出）写入
`docs/CONTROL_MAP.md`。与 Mock 不一致时先改 `MockBCR2000` 并补测试，再改引擎。

- [ ] HW0 环境基线：记录 USB 模式（预期 U-1）、固件版本、当前 Preset 编号；确认 App 连接 Port 1，
  记录 Port 2/3 的用途；分别记录冷启动、完全退出后重开、快速重开时是否出现 `OSStatus -304`。
- [ ] HW1 全部 108 个控件逐区学习：记录每个控件实际消息（CC / Note / NRPN、通道、按键发送值），
  与 Mock 的 CC 1–108 预设对照；检查冲突拒绝与自动前进。
- [ ] HW2 反馈与回显：测量收到反馈后是否回显及延迟，决定 `echoWindow` 是否保留 180 ms；
  按键 toggle / momentary 的发送值与本地 LED；LED 环显示模式对 7-bit 值的呈现；
  非当前编码器组收到反馈后切回是否显示新值。
- [ ] HW3 编码器模式与精度（WP7 的实机前提）：Relative 1/2 方向、中性码、幅度/加速度、回显；
  NRPN CC99/98/6/38 实际顺序、选择器是否每次重发、14-bit 回写与非当前组行为。
  Mock 的相关假设逐条标注“已证实 / 已修正”。
- [ ] HW4 连接可靠性：USB 断开/重插、休眠唤醒时连接快照与输入批次的顺序；
  重连后软件状态完整回写且不重放旧输入；实体断开时输出控制器停止输出。
- [ ] HW5 端到端闭环：MCP 写 `arm.j1=90` → 真机 P1-1 LED 更新；转动真机 P1-1 → MCP 读到新值；
  真机 B 行 Agent LED 随状态变化；真机 + OSC 仿真端的使能、限速、断线停机。
- [ ] HW6 高频与长时间：快速转动多个编码器时的 MIDI 输出速率、丢弃计数与 UI 帧率，
  作为 WP2 反馈调度的实测基线；30 分钟 soak 期间软件与硬件不分叉。

验收：R1 验收条件全部满足，`docs/CONTROL_MAP.md` 记录实测结论，Mock 与实测一致。

## C. 按实测结果修正（依赖 B）

- [ ] C1 按 HW2/HW3 结果调整 `MockBCR2000`、`echoWindow`、相对模式回显过滤与 NRPN 组包规则。
- [ ] C2 手工端点选择：多设备或非 Port 1 时可在 UI 中选择输入/输出端点，选择持久化，缺失时明确报错。
- [ ] C3 若 HW1 发现当前 Preset 不适合（例如消息重复、通道冲突），由用户决定是否调整 Preset，
  App 只给出冲突报告，不自动改设备。

## D. 设计改进与剩余工作包

- [ ] D1 OSC 每帧发送全部目标值（幂等），避免 UDP 丢包后某关节停在旧目标；
  停止帧重复发送；在 `docs/OSC.md` 写明接收端必须有超时自动停机。
- [ ] D2 相对编码器与 NRPN 微调在参数 `step` 大于单次增量时不动：按控件累积余量，
  或相对输入至少按方向走一步；补慢速转动测试。
- [ ] D3 WP2：反馈调度与 UI 刷新性能（以 HW6 实测为基线）
  - [ ] 同控件反馈合并、限速与错误抑制策略
  - [ ] `MonitorEvent` 标明反馈是否送达（成功发送 / 未连接丢弃 / 发送失败）
  - [x] 学习中替换配置时发出可见事件，并覆盖相应会话/UI 路径（随 WP4 实现）
- [ ] D4 MCP 参数变化推送（SSE 或通知），让 Agent 实时感知真机操作；需先确认协议方案。

## E. 远期

- [ ] 页面/层、宏（R4 剩余）；WebSocket / ROS 2 适配器（R5 剩余）
- [ ] R6 Codex 接入（见下方 P0-S4、M6）
- [ ] R7 公证发布与 macOS 14 安装验收
- [ ] 真实机械臂接入前的独立停机方案评审（硬件急停、执行端看门狗），未评审不得连接

## 无真机工作包记录（DEV_PROMPT.md）

- [x] WP1：可测试的会话层、设备适配器与整合测试
- [ ] WP2：反馈调度与 UI 刷新性能（移至 D3）
- [x] WP3：通用 MCP 控制接口（审查修正见 A1、A3）
- [x] WP4：持久化加固与配置导入导出
- [x] WP5：功能系统扩展（相对/步长问题见 D2）
- [x] WP6：安全门与 OSC 输出适配器、标准库仿真端（审查修正见 A2、D1）
- [x] WP7：absolute / relative1 / relative2、14-bit NRPN 与显式学习（仅 Mock，实机见 HW3）

## 界面修复

- [x] 恢复自定义无标题栏样式并保留双击放大；单击拖曳交给 AppKit，交通灯按钮与内容区不拦截。
- [x] 定位并修复空闲窗口拖曳卡顿：将面板外阴影从完整控件树移到机壳背景形状，
  保留 LED 光晕。Instruments 对照与限制见 [窗口拖曳分析](docs/WINDOW_DRAG_ANALYSIS.md)。
  WP2 仍等待确认。
- [x] 窗口自适应布局：面板按可用空间等比缩放（1.0–1.6 倍）并居中；宽屏时工作区移到面板右侧，
  检查器宽度随窗口在 330–400 pt 之间变化。

## CoreMIDI OSStatus -304 复现记录（待调查）

- [ ] 调查 `创建 MIDI Client 失败（OSStatus -304）`，记录重启、间隔和复现频率。

WP1 验证时没有实体 BCR2000，使用本机构建的 ad-hoc App。已观察到的操作路径：

1. 运行 `python3 configs/macos_workflow.py build` 和 `python3 configs/macos_workflow.py smoke`，
   再用 `open build/app/BCRAgentConsole.app` 打开普通 App；smoke 本身不启动 CoreMIDI。
2. 在 Mock 下操作旋钮、滑块与 Agent，切换实体模式检查未连接/学习提示后回到 Mock。
3. 重新构建并通过 smoke 后，用 AppleScript 请求退出旧 App，紧接着 `open` 曾返回启动错误
   `-600`；再次执行 `open` 后，App 界面连接详情显示 CoreMIDI 创建 Client 失败 `OSStatus -304`。
4. 此时 Mock 旋钮、滑块和设备源切换仍正常。没有实体 MIDI 输入，未验证真实连接。

这是一次观察到的复现路径，尚未证明每次均能复现，也未确定与快速重开或 `-600` 的因果关系。
后续应分别记录冷启动、等待完全退出后重开及快速重开的结果；不得把 smoke 通过视为 MIDI 启动通过。

## 后续开发 Plan（Todolist）

- [x] P0-S1：完成 Codex App Server 生命周期
  - [x] `CodexProcessSupervisor` 实现 App Server 进程 `launch/read/stderr/stdout/退出回收` 全链路，支持可控重启与崩溃恢复
  - [x] 错误码分类 + `stderr` 诊断日志脱敏落库
  - [x] 应用退出时无残留子进程与任务
- [x] P0-S2：完成 Codex Handshake 与 Thread/Turn 基础链路
  - [x] 实现 handshake：`initialize`、`initialized`、`account/read`、`model/list`
  - [x] 实现线程与回合基础链路：`thread/start|resume`、`turn/start|interrupt`
  - [x] `model/list` 采用分页读取并持久化模型能力（包括 effort/metadata）
  - [x] 生成与解析 `turn/started`、`turn/completed`、`item/*` 事件的最小状态机
- [x] P0-S3：审批安全门完整落地（无可见性误放行）
  - [x] 硬件 approve/decline 增加 `可见性 + slot-id + request-id + 时序窗口` 三重校验
  - [x] 实现 `commandExecution` / `fileChange` server request 的一次性响应：approve 与 decline 支持
  - [x] 审批请求超时、重复响应、重复 request 的幂等处理
  - [x] 无敏感信息日志：token/password/env/filepath/sensitive prompt 脱敏
- [ ] P0-S4：基础集成与稳定性
  - [ ] 关键集成测试：`mock app-server` + 真实 `swift test` 的 protocol/integration 覆盖
  - [ ] App Server 异常路径：提前退出、乱序响应、重复请求、错误响应、Malformed JSONL
  - [ ] `Stop All` 与重连场景下状态一致性回归

当前 M4/M5 的已完成项仍在保留，未完成项将按上面清单推进。

- [x] M0：工程骨架与 Mock 轨道已完成
  - [x] Swift Package + SwiftUI executable 建好
  - [x] Domain type 与基本状态机落地
  - [x] CoreMIDI 热插拔与原始事件展示
  - [x] 14 条单元测试 + 基础流程脚本

- [x] M1：端点发现与采集已完成
  - [x] BCR2000 枚举与重连回调稳定
  - [x] Note/CC 采集路径打通
  - [x] 快速学习绑定 8 槽位

- [x] M2：映射与反馈已完成（MVP）
  - [x] 映射文件持久化
  - [x] LED/旋钮反馈回写
  - [x] 回环抑制与 event echo 限制
  - [x] 硬件镜像页支持 32 控件状态展示（旋钮 + IN/OUT）

- [x] M3：Mock agent console 已完成
  - [x] 8 槽位状态机与 approval 流
  - [x] 长按 Stop All 与硬件交互
  - [x] UI 与硬件状态投影一致

- [x] M4：Codex Adapter 基础（P0）
  - [x] 固定 Codex CLI 与 JSON Schema 版本（0.145.0 文档化），增加 schema 生成与校验入口
  - [x] 建立 App Server 进程生命周期管理（启动/重启/关闭与日志分流）
  - [x] 完成 JSONL 传输、request-id 追踪、超时与失效响应处理
  - [x] 完成 handshake：`initialize`、`initialized`、`account/read`、`model/list`
  - [x] 完成 thread/turn 基础链路：`thread/start|resume`、`turn/start|interrupt`
  - [x] 加入最小 `Mock<->Codex` 契约测试（至少请求/响应超时与响应匹配）

- [x] M5：安全与批准（P0）
  - [x] Safe Read 与 Workspace Write 权限模型切换落地（无 network）
  - [x] 仅在可见 UI + 对应 slot/requestId 时允许硬件 approve/decline
  - [x] 命令执行与文件变更审批 request 一次性响应（支持 decline）
  - [x] `cwd` 与 writableRoots 规范化后再发起，阻断越界路径
  - [x] 脱敏审计日志（禁止写入 token、密码、环境变量、完整 prompt）

- [ ] M6：稳定性与回归（P1）
  - [x] Agent 同步触发后的旧 LED 效果顺序：反馈先于触发，回归测试覆盖按住期间的新 LED 和运行中→中断（WP1 审查修正）
  - [ ] 反馈调度器限速、同控件去重、错误抑制策略可配置化
  - [ ] 断线重连恢复策略：仅恢复软件快照，旧输入清空，不重放旧队列
  - [ ] 完成 protocol/状态机集成测试与 30 分钟 soak 验证
  - [x] 发布链路补齐：应用图标、独立版本/本机配置、Universal ZIP/DMG、签名/公证流程、校验与 CI
  - [ ] 运行远端发布 CI、真实 Developer ID 公证及 macOS 14 真机安装验收（流程见 docs/PACKAGING.md）

- [ ] M7：映射与可配置性（P1）
  - [x] 108 个物理控件模型、逐控件学习（自动跳到下一个）与冲突拒绝
  - [x] Mock BCR2000 设备与软件参数双向同步引擎
  - [x] 检查器：为每个控件分配参数 / Agent / 复位组，编辑参数范围与单位
  - [ ] 用实体 BCR2000 验证全部控件学习与 LED 回写（见 HW1、HW2）
  - [ ] 手工端点选择（多设备 / 非 Port 1）（见 C2）
  - [x] 14-bit（NRPN）高分辨率参数（Mock）；实体待 R1
  - [x] OSC 安全输出与仿真端；WebSocket / ROS 留待后续
  - [x] 编码器 absolute / relative1 / relative2（Mock）；实体回放标定待 R1
  - [x] 会话配置导入导出（不含实体映射与私密信息）

## WP3–WP7 审查修正

- [x] MCP 不可修改只读/使能定义及已有 agentWritable；自定义输出使能同样受保护。
- [x] 禁止自动恢复输出，启动/故障/重连需观察使能先关后开。
- [x] OSC 全量输出快照及关闭帧重发；仿真器独立控制帧超时停机。
- [x] 相对/NRPN 软件细调累积余量，清理外部修改和边界积压。
- [x] reset_group 跳过保护项并返回清单。
- [x] 大角度预览避免 Int 缩窄及三角函数溢出。
- [x] 修正测试文件 EOF 空行，并检查净改动与新增提交本身。
