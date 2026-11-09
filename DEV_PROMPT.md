# 外部开发任务说明（无真机阶段）

> 给外部开发者 / 开发 Agent 的完整任务说明。每个工作包完成后由 Claude 做代码审查。
> 编写：2026-11-09；2026-11-09 更新：加入 WP3 MCP 控制接口，原 WP3–WP6 顺延为 WP4–WP7，
> 明确只在 `main` 工作区开发与验收。对应 [ROADMAP.md](ROADMAP.md) 中不依赖实体 BCR2000 的部分。

---

## 0. 你的角色与背景

你在开发 **BCR Console**：一个 macOS 14+ 原生 SwiftUI / CoreMIDI 应用，把 Behringer
BCR2000 当作双向控制面板。实体控件可以驱动软件参数（例如机械臂关节角度），软件也会把
参数写回硬件的 LED 环和按键 LED。

**当前没有真机。** 所有工作都必须能用内置的 `MockBCR2000` 和单元测试完成并验证。

开始前先完整阅读：

1. `AGENTS.md`：项目契约与工具约束（**必须遵守**）
2. `CONTRIBUTING.md`：分支、提交、检查、架构、测试规范（**必须遵守**）
3. `ROADMAP.md`：阶段计划
4. `docs/CONTROL_MAP.md`：分层模型与同步规则
5. 核心代码：`Sources/BCRAgentCore/{BCRLayout,HardwareMap,SurfaceConfiguration,SurfaceEngine,MockBCR2000}.swift`
6. 应用层：`Sources/BCRAgentConsole/ConsoleViewModel.swift` 与各视图
7. 现有测试：`Tests/BCRAgentCoreTests/`

### 架构速览

```text
物理控件 BCRControlID（108 个）
  → HardwareMap（学习到的 MIDI 身份；Mock 有自带预设）
  → SurfaceConfiguration（参数定义 + 每个控件的功能分配）
  → SurfaceEngine（纯值类型；输入 → 参数 → 返回 [SurfaceEffect]）
  → ConsoleViewModel.perform(effects)（发送到 Mock 或 CoreMIDI、触发 Agent、提示）
```

软件参数是唯一事实来源：设备输入改变参数后，回写绑定同一参数的**其他**控件；
软件修改则回写**所有**绑定控件。

---

## 1. 全局约束（每个工作包都适用）

- **环境**：非交互 shell 先 `source $HOME/.config/dev-environment/environment.sh`。
  不要安装或升级工具链，不要新增 SwiftPM 第三方依赖（需要时先停下来说明理由）。
- **分支与提交**：始终在 `main` 工作区开发和验证。**不创建分支、不使用 `git worktree`、
  不另外 clone 仓库**来开发、验证或回测。
  - 按“改 → 在 `main` 工作区跑检查 → 提交”的顺序推进，一个提交对应一次通过检查的工作区状态；
    不要事后把混在一起的改动拆成多个提交，也不要回测历史提交。
  - 使用 Conventional Commits；完成后 `git pull --rebase origin main`，再 `git push origin main`。
  - 禁止强制推送，禁止创建或推送版本 tag。
- **共享工作区**：开始前先看 `git status`。如果有不属于你的未提交改动，不要覆盖、`stash`、
  `reset` 或擅自提交，先停下来说明。
- **提交前检查**：运行 `CONTRIBUTING.md` 第 2 节列出的全部命令；涉及 UI 时还要运行
  `build` 和 `smoke`，并在 Mock 模式下实际操作一遍。不得引入编译警告。
- **真机相关的假设**：凡是关于实体 BCR2000 行为的假设（相对模式编码、NRPN 行为、
  是否回显等），只能体现在 `MockBCR2000` 中，并在代码注释和 `docs/CONTROL_MAP.md` 中
  标注 **“待 R1 实机验证”**。手册见 `settings.md` 中的链接。不得猜测用户的实体预设。
- **不要改动**：Mock 预设的编号规则（CC 1–108，按面板顺序）、Codex 相关代码
  （`Codex*.swift`）、打包与 FreeCM 接线。确需修改时先停下来说明。
- **持久化**：修改 `HardwareMap` 或 `SurfaceConfiguration` 的编码格式时必须提升
  `currentVersion`，并给出可见的迁移或提示。
- **失败要可见**：不加静默回退。
- **测试**：每个新的状态转换、消息形状、功能类型或校验规则都要有聚焦的单元测试；
  涉及时间的逻辑把 `now: Date` 或时钟作为参数注入。
- **范围**：只做当前工作包的内容。发现范围外的问题，写进交接说明的“发现但未处理”，不要顺手改。

---

## 2. 工作包（按顺序执行）

**每完成一个工作包：推送 → 按第 3 节写交接说明 → 停下来等待审查。**
审查通过后再开始下一个。推送后工作区必须是干净的，审查方直接在同一个 `main` 工作区验收。

### WP1：可测试的会话层（R2 第 1 项）

**问题**：效果管线（`perform`、`receiveFromDevice`、`transmit`、设备源切换、学习提示、
跟随触碰、连接回写）都在 `ConsoleViewModel` 里。它直接依赖 `CoreMIDIService` 和
`MockBCR2000`，目前没有任何测试覆盖。

**要求**：

1. 在 Core 中定义设备边界，例如：
   ```swift
   @MainActor protocol SurfaceDevice: AnyObject {
       func send(_ message: MIDIVoiceMessage) throws
       // 输入回调与连接状态按你的设计提供
   }
   ```
   `MockBCR2000` 包一层适配器实现它；`CoreMIDIService` 在 App 层实现它（CoreMIDI 仍只在 App 层）。
2. 把与 UI 无关的编排逻辑移入 Core 中可测试的类型，例如 `@MainActor final class SurfaceSession`。
   它负责：持有 `SurfaceEngine`、执行 effects、按设备源路由、Mock/实体切换时整体回写、
   学习完成后的状态、丢弃反馈计数、MIDI 事件日志。
   `ConsoleViewModel` 只负责 UI 状态（选中项、提示文案、跟随触碰）和依赖装配。
3. Mock Agent 时间线可以留在 App 层，但触发和 LED 回写要经过会话层，并能在测试中观察到。
4. 新增集成测试，至少覆盖：
   - Mock 输入 → 参数 → 写回其他绑定控件；
   - 切换到未连接的实体设备时，丢弃计数增加且不抛出；
   - 实体设备连接后整体回写；
   - Mock 模式下的实体输入只记录、不执行；
   - 学习流程端到端：学习、自动前进、冲突拒绝、持久化回调被调用。
   用假设备（`FakeSurfaceDevice`）记录发送内容，不依赖 CoreMIDI。

**验收**：`ConsoleViewModel` 明显变薄；界面行为与现在一致；新测试全部通过。

### WP2：反馈调度与 UI 刷新性能（R2 第 2、3、5 项）

**问题**：

- 拖动参数滑块时每次变化都立即发送 MIDI，没有合并或限速。
- `ConsoleViewModel` 是一个 `ObservableObject`。`engine`、`mock`、`events` 中任何一个变化
  都会让整个窗口（108 个控件单元）重新计算 body。每条 MIDI 事件追加到 `events` 也会触发
  整窗刷新。

**要求**：

1. 在 Core 中实现 `FeedbackScheduler`（纯值类型，时钟可注入）：同一 `MIDIControlID`
   在一个周期内只发送最后一个值；有全局速率上限（可配置，默认值在交接说明中给出理由）；
   丢弃或延迟的数量可查询。为合并、限速、顺序和刷新写测试。
2. 输入路径也要批量处理：一个 CoreMIDI 回调中的多条消息只触发一次 UI 发布。
3. 降低 UI 刷新范围。推荐迁移到 Observation（`@Observable`，macOS 14 可用），
   或者把监视器事件、面板状态、检查器状态拆成独立的可观察对象。
   目标：一条 MIDI 输入只让受影响的控件单元和监视器重新计算。
4. 写一个确定性的随机测试（固定随机种子）：随机交替执行 Mock 操作和软件修改数千步，
   然后断言 Mock 中每个已分配控件的值与引擎期望的反馈值一致。
5. 在交接说明中给出前后对比：例如用 `Self._printChanges()` 或 Instruments 记录拖动一个
   旋钮时重新计算 body 的视图数量。
6. WP1 审查补充：`MonitorEvent` 标明反馈是否送达（成功发送 / 未连接丢弃 / 发送失败）；
   学习中替换配置时发出可见事件，并为这些状态补测试。

**验收**：拖动滑块不会刷屏（MIDI 监视器可见合并效果）；随机测试通过；界面行为不变。

### WP3：MCP 控制接口（R8 第 1–5 项）

**目标**：App 内置 MCP 服务，让外部 Agent（Claude Code、Codex 等）通过本机端口读取并修改参数。
Agent 写入与滑块写入**完全等价**：都经过 `SurfaceSession` 效果管线，界面、Mock / 实体 LED 同步更新。

**要求**：

1. **分层**：
   - Core：MCP / JSON-RPC 2.0 消息模型、协议版本协商、工具定义（含 JSON Schema）、参数校验、
     权限判断与工具执行（`AgentControlService` 一类的 `@MainActor` 类型，调用 `SurfaceSession`）。纯逻辑，可单元测试。
   - App：基于 `Network.framework` 的 HTTP 监听、请求解析、鉴权、UI 设置与状态展示。
   - 默认自行实现所需的最小协议子集，**不引入第三方依赖**。如果你认为官方 Swift MCP SDK 明显更合适，
     先停下来说明理由，由开发者决定。
2. **传输**：MCP Streamable HTTP，单一端点 `POST /mcp`，返回 `application/json`。
   - 支持 `initialize`、`notifications/initialized`、`ping`、`tools/list`、`tools/call`，以及会话头 `Mcp-Session-Id`。
   - 首版不要求 SSE 推送；不支持的方法返回规范的 JSON-RPC 错误。
   - 实现时以当时最新的稳定规范版本为准，在 `docs/MCP.md` 中写明协议版本。
3. **安全**（缺一不可）：
   - 只绑定 `127.0.0.1`；默认关闭，用户在 UI 中开启后持久化。
   - 端口固定、可配置。被占用时明确报错，**不得**自动改用随机端口。
   - Bearer token 首次启用时随机生成，保存在 Keychain，不进仓库和日志。缺少或错误的 token 返回 401。
   - 校验 `Origin` 头，拒绝非本机来源，防止 DNS rebinding。
   - 权限分级：`只读`、`参数写入`（默认开启）、`配置写入`（默认关闭，用于改分配和参数定义）。
   - 参数级开关 `agentWritable`：提升 `SurfaceConfiguration.currentVersion` 并迁移旧数据；
     示例配置中 `arm.enabled` 设为不可写。
   - 写入限速（可配置）；超限时返回明确错误，不静默丢弃。
4. **首批工具**（输入输出 schema 写入 `docs/MCP.md`）：
   - `get_status`：设备源、连接、丢弃计数、MCP 权限。
   - `list_parameters`：id、名称、分组、单位、范围、类型、当前值、是否可写、绑定控件。
   - `get_parameter`。
   - `set_parameter`：返回实际写入值；超出范围时返回 `clamped: true`，不得静默截断。
   - `set_parameters`：批量写入，先全部校验，任一失败则全部不写。
   - `nudge_parameter`：按增量修改。
   - `reset_group`。
   - `list_controls`：物理控件、分配、绑定状态、当前值。
   - `assign_control`、`create_parameter`、`update_parameter`：仅在开启“配置写入”时可用。
   - 工具执行失败返回 `isError: true` 和可读的原因（未知参数、无权限、限速、校验失败）。
5. **可见性**：
   - 顶栏显示 MCP 状态：关闭 / 监听中 / 活跃会话数。
   - 设置面板：端口、权限、复制 token、复制连接命令（例如
     `claude mcp add --transport http bcr-console http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <token>"`）、
     最近 100 次调用记录。
   - MIDI 监视器中，Agent 发起的写入标注来源 `AGENT`。
   - 一键停止服务（立即断开所有会话）。
6. **测试**：
   - Core 测试：协商、`tools/list` schema、每个工具的成功与失败路径、权限拒绝、批量原子性、
     clamp 标记、限速（时钟注入），以及“Agent 写入 → Mock LED 更新”的闭环。
   - Console 测试：本机回环的 HTTP 集成测试（端口 0），覆盖鉴权、Origin、会话头、端口占用报错。
   - 新增 `tools/mcp_smoke.py`（仅用 Python 标准库），对运行中的 App 执行
     initialize → tools/list → set_parameter → get_parameter，作为验收脚本。

**验收**（在 Mock 模式下）：
- 用 Claude Code 通过上面的连接命令接入，列出工具后调用 `set_parameter arm.j1 = 90`：参数滑块和 P1-1 灯环同步移动。
- 在面板上转动 P1-1 后，`get_parameter` 读到新值。
- 写入 `arm.enabled` 被拒绝；错误 token 返回 401；关闭服务后连接被拒绝。
- `tools/mcp_smoke.py` 通过。

### WP4：持久化加固与配置导入导出（R4 第 2 项 + 规范第 5 节）

**问题**：

- `AgentSlotID`、`MIDIControlID` 使用合成的 `Decodable`，会绕过初始化器中的 `precondition`，
  非法 JSON 可能产生越界值。
- `SurfaceConfiguration` 加载后没有整体校验：参数 ID 重复、分配指向不存在的参数、
  触发类功能分配给了编码器、Agent 槽位越界等。
- `ControlInspectorView` 中 `ParameterEditor` 的草稿只在参数 ID 变化时重置。如果同一参数
  在别处被修改（例如“恢复示例配置”），草稿会过期。

**要求**：

1. 为上述类型手写 `init(from:)` 并做范围校验，非法值抛出 `DecodingError`。
2. 新增 `SurfaceConfiguration.validate() throws`，返回或抛出具体的问题列表；加载时校验失败
   要显示可见提示，并且**不覆盖**用户的原文件（例如另存为 `.invalid` 备份后再载入示例）。
3. 配置导入 / 导出：使用 `NSSavePanel` / `NSOpenPanel`，JSON 文件**不包含**实体
   `HardwareMap`。导入前先校验，校验失败不替换当前配置。导出的格式就是带版本号的
   `SurfaceConfiguration`。
4. 修复草稿过期问题：外部修改时，未编辑的草稿自动刷新；已编辑的草稿要提示冲突。
5. 为每条校验规则、非法解码和导入失败路径写测试。

### WP5：功能系统扩展（R4 第 1、3 项，不含页面 / 层）

**要求**：

1. 新增 `ControlTarget` 的 case（每个都要有引擎测试和 Mock 闭环测试）：
   - `stepParameter(id, step)`：按键每按一次 ±步长，支持在边界处停止或循环；
   - `setParameter(id, value)`：按下时设为指定值；
   - `cycleParameter(id, values)`：每按一次在给定值之间循环。
   这些都属于触发类，只能分配给按键。LED 规则写入 `docs/CONTROL_MAP.md`。
2. `ParameterDefinition` 增加可选的步长 / 吸附值（`step`）。编码器输入和软件修改都要按步长
   取整，并注意与 7-bit 映射的往返一致性。
3. 检查器支持批量分配：选择一行（例如 E1）和一个参数组，按顺序绑定。冲突时预览差异并确认。
4. 检查器 UI 支持编辑上述新功能的参数。
5. 提升 `SurfaceConfiguration.currentVersion`，并处理旧版本迁移。

### WP6：安全门与外部输出适配器（R5，含仿真端）

**要求**（安全门对硬件、滑块、MCP 三种来源的写入一视同仁）：

1. 在 Core 中实现 `MotionSafetyGate`（纯值类型，时钟可注入）：
   - “使能”参数为关时不输出；
   - 每个参数可配置软限位、单周期最大变化量、最大速度（单位 / 秒）；
   - 输出值经过限幅和限速后再发出，**界面上要同时显示目标值和实际输出值**；
   - 心跳超时或适配器断开时立即停止输出，状态可见；
   - 可选：dead-man 模式（按住指定按键才允许输出）。
   每条规则都要写测试，包括边界值和时间推进。
2. 定义适配器边界 `ParameterSink`（输出）和 `ParameterSource`（外部实际状态回到引擎，
   例如关节实际角度，用于驱动 LED 环）。外部状态回写硬件的规则写入 `docs/CONTROL_MAP.md`：
   以目标值为准还是以实际值为准，要在界面上可选并说明。
3. 首个适配器：OSC over UDP，使用 `Network.framework`，不引入第三方依赖。
   地址格式例如 `/bcr/param/<parameter-id> <float>`，在文档中写明。为 OSC 编解码写测试。
4. 仿真接收端：`tools/arm_sim.py`，只用 Python 标准库。接收 OSC 后按速度上限模拟关节运动，
   并把实际角度回发。启动方式写入 README。
5. App 中增加“输出”设置：目标地址和端口、启停、连接与心跳状态、安全门状态。
   不能静默失败。

**验收**：Mock 面板转动 J1 时，仿真端的实际角度受速度上限约束，并能回到 UI；
关闭“使能”或停止仿真端后，500 ms 内 UI 告警并停止输出。

### WP7：编码器模式与 14-bit（R3，仅 Mock，待实机验证）

**要求**：

1. `ControlAssignment` 增加编码器模式：`absolute`（默认）、`relative1`、`relative2`。
   具体编码以手册为准，在 `MockBCR2000` 中实现，并标注“待 R1 实机验证”。
   相对模式下参数按“步长 × 加速度”累加，不受 7-bit 分辨率限制。LED 环仍按绝对位置回写。
2. 14-bit NRPN：在 `MIDIModels.swift` 中增加 NRPN 的编解码（CC 99/98/6/38 序列，需要
   跨消息状态）。`HardwareMap` 和学习流程要能识别 NRPN 身份；回写也使用 NRPN。
   新的消息形状都要写测试，包括消息交错和不完整序列。
3. Mock 支持以上模式，并有闭环测试。
4. 提升持久化版本。

---

## 3. 每个工作包的交接说明

在最终回复中提供以下内容；提交正文中写其中的精简版：

```markdown
## WPn 交接
- 提交：<hash 列表>（推送后的 `main` HEAD：<hash>，工作区干净）
- 改动概述：<3–6 条，说明做了什么、为什么>
- 设计取舍：<备选方案及选择理由>
- 测试：<新增测试名单；全部检查命令与结果，失败的如实写出>
- 手动验证：<在 Mock 模式下操作了什么、看到了什么；未做的写“未做”>
- MCP 冒烟：<WP3 完成后每个工作包都要执行 `tools/mcp_smoke.py` 并附上结果；WP3 之前写“不适用”>
- 待实机验证：<依赖真机行为的假设>
- 发现但未处理：<范围外的问题>
- 需要审查重点关注：<你最没把握的地方>
```

同时更新 `ROADMAP.md` / `TODO.md` 中对应的勾选项。

---

## 4. 审查标准（Claude 会检查）

1. **正确性**：同步规则不被破坏（谁回写谁、回环抑制、去抖）；边界值、时间推进、错误路径。
2. **分层**：Core 无 SwiftUI / CoreMIDI；视图不直接发送 MIDI，不包含业务规则；所有写回都经过效果管线。
3. **Mock 一致性**：所有设备行为假设都在 Mock 中，有测试，并标注了是否待验证。
4. **测试质量**：测的是行为而不是实现细节；时间可注入；没有依赖 `sleep` 的不稳定测试。
5. **失败可见**：没有吞掉的错误，没有静默回退。
6. **持久化兼容**：版本号已提升，旧数据有迁移或可见提示，不会丢失用户文件。
7. **Swift 6 并发**：没有 `@unchecked Sendable` 滥用，没有为了消除警告而加 `nonisolated(unsafe)`。
8. **范围与提交**：只做当前工作包；提交原子、信息规范；没有分支、worktree 或额外 clone；
   已推送到 `main`，推送后工作区干净。
9. **交接如实**：说明中的“已验证”必须有对应的命令输出或操作记录。
10. **Agent 接口安全**（WP3 起）：MCP 写入只经过会话管线；权限、token、Origin、限速、
    `agentWritable` 均生效，拒绝的请求有明确的错误和调用记录。

### 每轮验收流程

1. 开发方推送后，审查方在同一个 `main` 工作区执行 `git pull --rebase origin main`，确认工作区干净、
   HEAD 与交接说明一致。
2. 在 `main` HEAD 上复跑 `CONTRIBUTING.md` 第 2 节的全部检查；涉及 UI 的，构建并打开 App 实测。
3. WP3 完成后，每轮都在运行中的 App 上执行 `tools/mcp_smoke.py`；审查方可以直接通过 MCP 驱动 App 验证。
4. 不为审查创建分支、worktree 或另外 clone；需要修正时，在 `main` 上追加 `fix` 提交并推送。

审查结论分三级：**通过** / **小改后通过**（直接在 `main` 上追加 fix 提交）/ **需返工**。
