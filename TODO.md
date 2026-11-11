# BCR2000 Agent Console 开发 TODO

> 阶段目标与验收标准见 [ROADMAP.md](ROADMAP.md)，开发与提交规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。
> 本文只保留未完成事项；已完成事项见 git 历史与 `docs/` 下的交接、实测记录。

状态（截至 2026-11-11）：

- Mock 下 WP1、WP3–WP7 及审查修正全部完成并已推送；手工端点选择、OSC 幂等帧、细调余量已完成。
- 本机通过开发签署的 DriverKit codeless dext 修复 USB OUT 管道后，实体双向可用（SIP 保持启用）。
  这是当前实机验证的前提，见 [DriverKit 实测](docs/DRIVERKIT_USB_PROOF.md)。
- 实体已确认：固件 1.10、U-1、Preset 8、App 连接 Port 1；已学习 56/108（全部旋钮位置），
  经 MCP 的 280/280 设备回读一致。按键、旋钮按下、人工转动与视觉验收尚未进行，
  见 [实机记录](docs/HARDWARE_VALIDATION.md)。

执行顺序：0 仓库整理 → 1 实机验证 → 2 按实测修正 → 3 反馈调度与 MCP 推送 → 4 Codex 接入 → 5 发布 → 6 远期。
第 0、4 项不依赖真机，可在等待现场操作时并行。

## 0. 仓库整理（2026-11-11 盘点）

Swift 源码无需先行重构：最大文件约 560 行，Core/App 分层清晰，`@unchecked Sendable` 仅两处且均为
私有传输对象。需要整理的是与当前实现脱节的文档和零散文件：

- [ ] Z2 `docs/CONTROL_MAP.md` 中部保留了重构前的 8 槽位说明（“为什么采用快速学习”至“硬件镜像页面”），
  且 WP6/WP7 的现行内容排在这段“历史参考”之后。删除或移出历史段落，现行内容前移。
- [ ] Z3 `docs/DEVELOPMENT_DESIGN.md` §15 的里程碑快照与本文矛盾（M4/M5 仍未勾选，
  P0-S1…S5 的含义与本文的 P0-S4 不同）。改为指向本文与 ROADMAP，或明确标注为历史设计。
- [ ] Z4 `tools/verify_{configuration,endpoint,functions,output,precision,review_fixes}_ui.py`
  六个脚本没有被任何文档、测试或 CI 引用。逐个确认仍可运行：保留的写入验收文档，其余删除。
- [ ] Z5 根目录 `settings.md` 是零散的 U-1 模式设置笔记：并入 README“第一次连接 BCR2000”或
  `docs/HARDWARE_VALIDATION.md` 后删除。
- [ ] Z6（可选）一次性交接文档（`docs/WP1…WP7_HANDOFF.md`、`REVIEW_FIXES.md`、
  `ENDPOINT_DIAGNOSTICS_HANDOFF.md`、`MAC_TEST_PREPARATION_HANDOFF.md`）与根目录 `DEV_PROMPT.md`
  移入 `docs/archive/` 并修正链接，让 `docs/` 顶层只留现行参考。

## 1. 实机验证（R1，进行中）

规则：只在 Mock 关闭、实体模式下进行；不连接真实机械臂（OSC 只连 `tools/arm_sim.py`）；
App 与工具只发送只读查询 SysEx，不改写设备 Preset，不回放备份。
学到的映射只存在 Application Support，不进 git；结论（不含个人 Preset 原始导出）写入
`docs/CONTROL_MAP.md`。与 Mock 不一致时先改 `MockBCR2000` 并补测试，再改引擎。
设备快照回读不等同于人工转动或灯环视觉验收，两者分别记录。

- [ ] HW0 环境基线（剩余）：记录 Port 2/3 的用途；分别记录冷启动、完全退出后重开、快速重开时
  是否出现 `创建 MIDI Client 失败（OSStatus -304）`，并记录复现频率。
  已有观察：快速重开（`open` 先返回 `-600`）后出现过一次；无 BCR 的 Mac 虚拟客户端自检出现过一次、
  重试即成功。均未确定因果；smoke 通过不视为 MIDI 启动通过。
- [ ] HW1 剩余 52 个控件（按键、旋钮按下）逐区学习：记录实际消息（CC / Note、通道、按键发送值），
  检查冲突拒绝与自动前进；56 个旋钮位置逐个人工转动核对方向与映射。
- [ ] HW2 反馈与回显：测量收到反馈后是否回显及延迟，决定 `echoWindow` 是否保留 180 ms；
  按键 toggle / momentary 的发送值与本地 LED；LED 环显示模式对 7-bit 值的呈现；
  非当前编码器组收到反馈后切回是否显示新值（视觉确认）。
- [ ] HW3 编码器模式与精度：Relative 1/2 方向、中性码、幅度/加速度、回显；
  NRPN CC99/98/6/38 实际顺序、选择器是否每次重发、14-bit 回写与非当前组行为。
  Mock 的相关假设逐条标注“已证实 / 已修正”。
  前置决定：Preset 8 的 56 个旋钮均为普通绝对 CC，实测 Relative/NRPN 需要设备上存在这类控件定义；
  由用户决定是否在备用 Preset 上手工配置，App 不写设备。
- [ ] HW4 连接可靠性：USB 断开/重插、休眠唤醒时连接快照与输入批次的顺序；
  重连后软件状态完整回写且不重放旧输入；实体断开时输出控制器停止输出；
  重插后 DriverKit 覆盖是否仍然生效（OUT 包长 8）。
- [ ] HW5 端到端闭环（剩余）：转动真机 P1-1 → MCP 读到新值；真机 B 行 Agent LED 随状态变化；
  真机 + OSC 仿真端的使能、限速、断线停机。（MCP 写入 → 设备值回读已通过。）
- [ ] HW6 高频与长时间：快速转动多个编码器时的 MIDI 输出速率、丢弃计数与 UI 帧率，
  作为第 3 节反馈调度的实测基线；30 分钟 soak 期间软件与硬件不分叉。

验收：R1 验收条件全部满足，`docs/CONTROL_MAP.md` 记录实测结论，Mock 与实测一致。

## 2. 按实测结果修正（依赖第 1 节）

- [ ] C1 按 HW2/HW3 结果调整 `MockBCR2000`、`echoWindow`、相对模式回显过滤与 NRPN 组包规则。
- [ ] C3 若 HW1 发现当前 Preset 不适合（例如消息重复、通道冲突），由用户决定是否调整 Preset，
  App 只给出冲突报告，不自动改设备。
- [ ] C4 按 HW4 结果落实重连策略：只恢复软件快照，清空旧输入，不重放旧队列；补回归测试。

## 3. 反馈调度与 MCP 推送（R2 / R8 剩余）

- [ ] D3 WP2：反馈调度与 UI 刷新性能（以 HW6 实测为基线）
  - [ ] 同控件反馈合并、全局限速与错误抑制，策略可配置
  - [ ] `MonitorEvent` 标明反馈是否送达（成功发送 / 未连接丢弃 / 发送失败）
  - [ ] MIDI 输入批量进入引擎，UI 每帧最多发布一次
- [ ] D4 MCP 参数变化推送（SSE 或通知），让 Agent 实时感知真机操作。
  需先确认协议方案，以及是否引入官方 Swift MCP SDK（新增第三方依赖，需批准）。

## 4. Codex 接入（R6，不依赖真机）

App Server 生命周期、Handshake、Thread/Turn 链路与审批安全门已在 `BCRAgentCore` 完成，
但 `BCRAgentConsole` 尚未引用任何 Codex 类型（App 仍只跑 Mock Agent），
`CodexProcessSupervisor` 也没有测试。剩余：

- [ ] P0-S5 把 Codex 会话接入 App：依赖注入、Mock / Codex 切换与可见的失败状态；
  补 `CodexProcessSupervisor` 测试。
- [ ] P0-S4 基础集成与稳定性
  - [ ] 关键集成测试：`mock app-server` + 真实 `swift test` 的 protocol/integration 覆盖
  - [ ] App Server 异常路径：提前退出、乱序响应、重复请求、错误响应、Malformed JSONL
  - [ ] `Stop All` 与重连场景下状态一致性回归
  - [ ] protocol/状态机在 30 分钟 soak 下无分叉

## 5. 发布与 DriverKit 分发（R7）

当前选择：自用阶段，main/PR 与 tag 的 CI 固定为无需凭证的 ad-hoc 主程序构建；
正式 DriverKit 分发申请与凭证配置**暂停**，待用户明确需要公开完整版时再推进。
流程见 [PACKAGING.md](docs/PACKAGING.md)、[TAG_RELEASE_SETUP.md](docs/TAG_RELEASE_SETUP.md)。

- [ ] 本机 dext 维护：记录开发 profile 到期日，以及 macOS 升级或重装后的重新验证步骤
  （身份、快照、五值回读、灯环）；失效时实机验证随之阻塞。
- [ ] macOS 14 真机安装验收（ad-hoc 主程序包）。
- 以下项在恢复正式分发后进行：
  - [ ] Apple 正式 entitlement 审核及两个 Developer ID profiles（申请草稿已备，尚未提交）。
  - [ ] 账号持有人批准凭证用途并安全配置 CI Secrets。
  - [ ] 使用正式授权运行签署/公证，并在未注册的干净 Mac 验证安装、卸载、升级与 USB。

## 6. 远期

- [ ] 页面/层、宏（R4 剩余）；多套配置的命名库管理
- [ ] WebSocket / ROS 2 适配器（R5 剩余）
- [ ] MCP 更多工具（触发 Agent 槽位、切换设备源）与 stdio 桥接（R8 后续）
- [ ] 真实机械臂接入前的独立停机方案评审（硬件急停、执行端看门狗），未评审不得连接
