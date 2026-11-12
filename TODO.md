# BCR2000 Agent Console 开发 TODO

> 工作区统一后续排期见 `AstroController/TODO.md`（工作区文件）。阶段目标与验收标准见 [ROADMAP.md](ROADMAP.md)，开发与提交规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。
> 本文只保留未完成事项；已完成事项见 git 历史与 `docs/` 下的交接、实测记录。

通用领域隔离与外部设备/模拟器供应方接口的新增需求见 [领域与接口 TODO](TODO_DOMAIN_INTERFACES.md)。
该文档保留已交付的设计与验收依据；共享插件迁移已完成，剩余工作不自动启动。

状态（截至 2026-11-12）：

- 按压动画及只读按钮身份导入已实现；32 个未配置和 2 个同址按键的临时预设修改待确认后执行。

- GUI 启动硬件值回读完成，56/56 实机值同步；激活组/当前预设号未从协议取得，保留明确的未知状态。

- BCR/XTouch同SHA的M1/M2/M3软件接入与新旧接口验证已完成；远端发布/CI和实机仍待处理，见 [共享插件接入](docs/SHARED_PLUGINS.md)。
- FreeCM Config 已接到 `build/seed` 依赖获取与编译，Build 构建主仓库；依赖锁参与配置就绪检查。
- 仓库整理 Z2–Z6 已完成；六项隔离 Mock UI 验收均通过，入口见 [原生 UI 验收](docs/UI_ACCEPTANCE.md)。
- 当前灯环两类模式的低端边界已校准；全量视觉扫描与其他显示模式保留待验，见 [控件映射](docs/CONTROL_MAP.md)。
- 中英双语与语言设置完成：默认跟随系统，可选择简体中文 / English，重启生效。

- Mock 下 WP1、WP3–WP7 及审查修正全部完成并已推送；手工端点选择、OSC 幂等帧、细调余量已完成。
- 默认配置保持领域中性；预置切换的回显策略、已移除 LED 清零与同配置重载停机已补回归测试。
- 本机通过开发签署的 DriverKit codeless dext 修复 USB OUT 管道后，实体双向可用（SIP 保持启用）。
  这是当前实机验证的前提，见 [DriverKit 实测](docs/DRIVERKIT_USB_PROOF.md)。
- 实体已确认：固件 1.10、U-1、Preset 8、App 连接 Port 1；已学习 56/108（全部旋钮位置），
  经 MCP 的 280/280 设备回读一致。按键、旋钮按下、人工转动与视觉验收尚未进行，
  见 [实机记录](docs/HARDWARE_VALIDATION.md)。

执行顺序：1 实机验证 → 2 按实测修正 → 3 真机反馈参数校准 → 发布/真实执行端评审。
非硬件软件实现已完成；正式分发仍按既有决定暂停。

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

## 3. 非硬件开发验收

D3 软件部分、D4、P0-S4/P0-S5、页面/层/宏、配置库、WebSocket/ROS 2 rosbridge、
MCP Agent/设备控制工具与 stdio 桥接均已实现并通过非硬件回归。
已实现并提交未绑定控件学习/停止、配置写权限关闭与程序化凭据管道启动。
详细范围、测试入口与限制见 [非硬件验收](docs/OFFLINE_ACCEPTANCE.md)、[Codex](docs/CODEX.md)、
[网络输出](docs/NETWORK_OUTPUT.md)、[MCP](docs/MCP.md)。
30 分钟 JSONL soak 已通过：墙钟 1800.091 秒、264,873 个 Turn、八个槽位，无分叉/失败。

- [ ] D3 真机调度参数校准：按 HW6 的输出速率、丢弃数、CPU/UI 帧率确定实体设备默认策略；
  软件限速/合并/错误冷却已经完成，当前默认关闭，不能把模拟结果当作真机基线。

## 5. 发布与 DriverKit 分发（R7）

当前选择：自用阶段，main/PR 与 tag 的 CI 固定为无需凭证的 ad-hoc 主程序构建；
正式 DriverKit 分发申请与凭证配置**暂停**，待用户明确需要公开完整版时再推进。
流程见 [PACKAGING.md](docs/PACKAGING.md)、[TAG_RELEASE_SETUP.md](docs/TAG_RELEASE_SETUP.md)。

开发 profile 已按用户授权取得并完成签署验证；到期日及升级/重装后的身份、快照、五值回读和灯环
复核步骤见 [DriverKit 维护](docs/DRIVERKIT_USB_PROOF.md#开发签署维护2026-11-11-更新)。实际 USB 重验仍属 R1。

- [ ] macOS 14 真机安装验收（ad-hoc 主程序包）。
- 以下项在恢复正式分发后进行：
  - [ ] Apple 正式 entitlement 审核及两个 Developer ID profiles（申请草稿已备，尚未提交）。
  - [ ] 账号持有人批准凭证用途并安全配置 CI Secrets。
  - [ ] 使用正式授权运行签署/公证，并在未注册的干净 Mac 验证安装、卸载、升级与 USB。

## 6. 真实执行端评审

- [ ] 真实机械臂接入前的独立停机方案评审（硬件急停、执行端看门狗），未评审不得连接。
  该项必须结合具体执行端与独立硬件保护，不能用已完成的软件模拟测试替代。

## 2026-11-12：公开软件 Surface 模拟

新增可选 `surface_control_*` 1.0 合同、稳定 Mock profile、CAS 输入与独立显示反馈。
显式 `--simulation-profile` 提供普通演练参数；输入/反馈/reset 权限默认关闭，不能绕过参数保护或注入 hardware。
通用 Python SDK 与可选 Pipe taskless 平台闭环示例随自包含交付件提供；既有 Provider1.0 与实体资格状态保持。
接入与边界见 [SURFACE_SIMULATION.md](docs/SURFACE_SIMULATION.md)。
