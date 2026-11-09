# BCR2000 Agent Console 开发 TODO

> 阶段目标与验收标准见 [ROADMAP.md](ROADMAP.md)，开发与提交规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

状态（截至 2026-07-27）：Swift MVP（Mock）与硬件镜像、双向反馈、基础映射已实现。当前待办聚焦于 Codex 接入与安全生产化。

## 无真机工作包（DEV_PROMPT.md）

- [x] WP1：可测试的会话层、设备适配器与整合测试（审查小改后通过，修正已追加，待确认）
- [ ] WP2：反馈调度与 UI 刷新性能
  - [ ] `MonitorEvent` 标明反馈是否送达（成功发送 / 未连接丢弃 / 发送失败）
  - [ ] 学习中替换配置时发出可见事件，并覆盖相应会话/UI 路径
- [ ] WP3：MCP 控制接口（本机端口、token、权限分级、参数工具、`tools/mcp_smoke.py`）
- [ ] WP4：持久化加固与配置导入导出
- [ ] WP5：功能系统扩展
- [ ] WP6：安全门与外部输出适配器（同样约束 MCP 写入）
- [ ] WP7：编码器模式与 14-bit（仅 Mock）

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
  - [ ] 用实体 BCR2000 验证全部控件学习与 LED 回写
  - [ ] 手工端点选择（多设备 / 非 Port 1）
  - [ ] 14-bit（NRPN）高分辨率参数，供机械臂关节精调
  - [ ] 参数输出适配器（OSC / WebSocket / ROS）把参数推给外部系统
  - [ ] 支持切换编码器输入模式（absolute / relative）及回放标定
  - [ ] 会话配置导入导出（不包含用户私密信息）
