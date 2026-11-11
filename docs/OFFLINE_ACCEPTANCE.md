# 非硬件 TODO 验收（2026-11-11）

本文件记录 `65f252f` 阶段的初始非硬件验收，不代表后续审查项目已经通过；
审查修复与当前行为另见 git 历史、CODEX.md、CONTROL_MAP.md、MCP.md 与 NETWORK_OUTPUT.md。
开发始终在 main 工作区进行，推送以用户明确授权为准。
没有把 USB、真实机械臂、macOS 14 安装、正式分发或真实急停评审标记为通过。

| TODO | 实现及非硬件证据 |
| --- | --- |
| D3 软件 | 可配置令牌桶限速、同控件合并、错误冷却；实际送达/断线丢弃/失败监视；批次保序与 16 ms UI/触碰合并；假设备/注入时钟回归 |
| D4 | 认证 SSE；现代/旧版握手、快照、递增 revision、变更回读、未授权拒绝；真实隔离 App 验收 |
| P0-S5 | 默认 Mock，明确切换 Codex；依赖注入、失败可见、模型/任务/权限配置、槽位与 LED 管线；controller 回归与真实 CLI 只读握手 |
| P0-S4 | Python mock app-server + 真实 JSONL 子进程；Thread/Turn/审批/异常路径/Stop All/新会话重连；另有长时间墙钟 soak |
| R4 剩余 | 页面/层切换、基础分配恢复、值保留、LED 快照、宏顺序/范围/去抖/级联删除；配置 v4→v5 迁移及持久化回归 |
| 配置库 | 本轮之前已完成；保存/确认载入/确认删除，损坏文件与写入失败保护 |
| R5 剩余 | WebSocket JSON 和 ROS 2 rosbridge；真实 URLSession/RFC6455 模拟端，验证心跳/状态/命令/停止；复用现有安全门 |
| R8 后续 | Agent/设备控制独立权限默认关闭，审计/限速；stdio 桥接完整握手/工具调用/会话清理 |
| dext 维护 | 用户另行授权 Xcode 开发 provisioning，开发宿主/dext 签署与当前设备覆盖检查通过；到期日与重验步骤已记录 |

## 常规验证

- 274 项 Swift 测试、52 项建置流程测试通过；格式、命令 manifest、diff 检查通过，无新增编译警告。
- 原生签署构建与中英文 1200 × 760 窗口启动通过；翻译源消息覆盖检查无遗漏（672 项）。
- 应用自身生成并检查中英文主窗口及 7 个设置/输出页面快照，存放在忽略的 build/ui-validation。
- 设置意图、配置管理、Codex 控制器由聚焦测试覆盖。原有辅助功能点击脚本是额外的人工发布验收入口，
  本轮没有把它们写成已执行。
- 两版 HTTP MCP、SSE 与 stdio 桥接均对运行中的隔离 Debug App 验收。
- 本机 Codex CLI 0.167.1 initialize、account/read、model/list 成功，返回 8 个目录模型；没有启动真实推理。

## 长时间验证

长时间验收使用独立复制的本地 XCTest 产物，避免 SwiftPM 锁阻塞后续构建，仍是 main 工作区构建的同一套真实
JSONL／八槽位测试，不是另一个 checkout 或模拟时钟。本轮于 2026-11-11 15:27:29 至 15:57:29（本机时区）完成：
墙钟 **1800.091 秒、264,873 个 Turn、八个槽位、0 失败**。
测试产物覆盖有序管道修复后的稳定 Thread/Turn 路径；其后的队列容量限制、审批重放与 UI 修改另经最终完整回归，
没有将更早那次失败或中断的运行计作通过。

## 重现入口

```bash
swift test --build-path build/swiftpm
python3 -m unittest discover -s Tests/BuildWorkflowTests
python3 configs/macos_workflow.py build
python3 configs/macos_workflow.py smoke
python3 tools/mcp_integration.py --script tools/verify_parameter_events.py
python3 tools/mcp_integration.py --script tools/verify_stdio_bridge.py
```

30 分钟 soak 的普通入口见 CODEX.md；执行期间 SwiftPM 持有构建锁，若还要继续编译，使用复制的 XCTest
产物通过 `xcrun xctest -XCTest BCRAgentCoreTests.CodexSessionIntegrationTests/testProtocolAndStateMachineSoak <bundle>` 运行，
并设置 `BCR_CODEX_SOAK_SECONDS=1800`。该测试完全离线，不读取用户凭据、不执行外部工具任务。

硬件相关余项仍在 TODO.md：R1、按实测修正、D3 真机参数校准、macOS 14 真机安装、独立停机评审。
正式 DriverKit 分发仍暂停；本次开发签署不是发行签署或扩展激活验收。
