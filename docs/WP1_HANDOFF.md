# WP1 交接：可测试的会话层

状态：WP1 审查结论为小改后通过；已追加下述审查修正，等待确认后再开始 WP2。提交 hash 见交接回复。

## 改动概述

- Core 新增 `SurfaceDevice`、连接快照与 `MockSurfaceDevice`；CoreMIDI 适配器继续位于 App。
- `SurfaceSession` 持有引擎，负责效果执行、设备路由、连接/切换整体回写、学习、丢弃计数及最近 300 条 MIDI 事件。
- 注入时钟、映射/配置保存与 Agent 回调，使设备错误、持久化错误和学习流程可通过假设备测试。
- `ConsoleViewModel.swift` 从 485 行缩减为 306 行，保留 UI 选中项、提示、跟随触碰及依赖装配；Mock Agent 时间线保持在 App，触发和 LED 回写经过会话。
- 配置替换时引擎保留 Agent LED 快照，避免 App 恢复状态时丢弃效果或重复发送；持久化格式与版本不变。
- 同步更新 README、控制映射文档、贡献规范、ROADMAP 与 TODO；未进入 WP2–WP6。

## 设计取舍

选择 `@MainActor final class SurfaceSession` 加语义事件回调，没有把 Combine 或 SwiftUI 引入 Core。
相较于直接测试依赖 CoreMIDI 的 ViewModel，这样能注入假设备和时间并独立观察效果；相较于这次
就迁移 Observation，保留现有 `ObservableObject` 桥接能把刷新优化留给 WP2。

CoreMIDI 保留原串行队列传输实现，外加主线程适配器；原有 `@unchecked Sendable` 只存在于私有
传输类，未增加使用范围。会话只接收解码后的值批次，不接触 CoreMIDI endpoint。

设备断线时计数、不排队；重连发送当前快照。未实现 WP2 的限速、合并和发布范围优化。
已学习控件的重复输入保持原规则：忽略重绑定并更新显示，不对每次编码器 tick 弹出冲突警告；
非法消息类型则有拒绝通知。

## 测试

全部通过，无编译警告。新增 19 条测试（18 条会话整合测试、1 条引擎测试），Swift 总计 81 条。
会话测试不导入 CoreMIDI、不依赖 sleep，使用 `FakeSurfaceDevice` 与注入时钟。

| 命令 | 结果 |
|---|---|
| `swift test --build-path build/swiftpm` | 81 条通过，0 失败 |
| `python3 -m unittest discover -s Tests/BuildWorkflowTests -v` | 19 条通过 |
| `python3 configs/validate_repo_commands.py .` | 通过（3 Configs、10 variants） |
| `git diff --check` | 通过 |
| `python3 configs/macos_workflow.py build` | 通过，ad-hoc 签名校验通过，无编译警告 |
| `python3 configs/macos_workflow.py smoke` | 原生窗口首帧及图标检查通过 |
| `python3 -m compileall -q configs` | 通过 |
| `python3 configs/source_root_workflow.py --help` | 通过 |

所有非交互 shell 均先加载开发环境。没有安装工具链或新增第三方依赖。

新增测试名单（`SurfaceSessionTests`）：

- `testMockInputUpdatesParameterAndOnlyMirrorsOtherControl`
- `testSoftwareParameterAndResetWriteAllMockBindings`
- `testDisconnectedHardwareSwitchCountsDroppedFeedbackWithoutSending`
- `testReconnectWritesCurrentSnapshotAndDoesNotReplayOldFeedback`
- `testHardwareInputInMockModeIsLoggedButDoesNotTouchParametersOrAgent`
- `testSwitchBackToMockPreservesParametersAndSeparateHardwareMap`
- `testLearningAdvancesRejectsConflictsAndPersistsOnlyAcceptedBindings`
- `testLearningLastControlFinishesAndButtonReleaseDoesNotLearn`
- `testLearningStopSwitchUnbindAndResetPersistHardwareMap`
- `testAgentTriggerAndFeedbackRunThroughSessionAndSurviveConfigurationReset`
- `testSendFailureReportsErrorAndCountsEveryDroppedMessage`
- `testLearningPersistenceFailureRemainsVisibleAndKeepsInMemoryMapping`
- `testConfigurationEditsPersistAndWriteFeedback`
- `testNewParameterUsesControlKindAndPersistsAssignment`
- `testConfigurationValidationAndSaveErrorsAreObservable`
- `testInjectedClockControlsTriggerDebounce`
- `testInjectedClockControlsFeedbackEchoSuppression`
- `testMonitorIsBoundedClearsAndKeepsMonotonicIDs`

引擎测试：`SurfaceEngineTests.testConfigurationReplacementResetsParametersAndPreservesAgentSnapshot`。

## 原生界面实际操作

通过 macOS Accessibility 操作构建出的 App，检查 1200 × 760 内容区（外框为 1200 × 788）：

- Mock P1-1 增加一格，面板/IN 变为 65，J1 显示约 4°，检查器跟随选中。
- 参数滑块执行增量操作，J1 显示约 40°，Mock 面板/OUT 同步变为 78。
- 切换实体模式，显示 Port 1 未连接提示；开始学习显示 P1-1 学习提示，停止后可返回 Mock。
- Mock B1-1 启动 Agent 1，等待批准时 LED 值为 96；再次按下批准，完成后 LED 值为 72。
- 打开 MIDI 监视页，确认 Mock IN/OUT 与控件身份持续记录。
- 1200 × 760 下查看实际窗口截图：面板和检查器正常显示，内容可滚动。截图仅保留在被忽略的 build 目录。

最终重开构建后的 App 时，CoreMIDI 创建 Client 曾返回 `OSStatus -304`，界面连接详情可见。
Mock 旋钮、滑块与设备源切换仍可操作；没有把这次真实 CoreMIDI 启动记为通过。
`smoke` 使用临时存储并关闭 MIDI，只验证原生首帧与图标，不代表真实 MIDI 可用。

实体学习输入、热插拔与异常设备未做原生真机操作；相关会话行为由假设备整合测试覆盖。

## 待 R1 实机验证

Mock 不回显、momentary 按键、组切换与非当前组 LED 记忆，以及现有 180 ms 回环窗口。
本次没有增加实体设备行为假设，也没有更改 Mock CC 1–108 的编号规则。

## 发现但未处理

- 初次交接发现的 Agent 旧 LED 反馈覆盖问题已在审查修正中处理，见下节。
- UI 仍通过整个 ViewModel 发布；触碰跟随和嵌套 Agent 回调可能导致多次通知。这是 WP2 的目标。

## 需要审查重点关注

主线程回调中的 Agent 重入和旧反馈顺序；连接快照到达时整体回写的边界；语义事件转 UI 提示时，
确保保存/发送错误始终保留可见。CoreMIDI 的真实连接与消息时序仍需 R1 验证。


## WP1 审查修正

- `SurfaceEngine.apply` 的 Agent 分支改为先反馈、后触发，避免同步回调的新 LED 值被旧快照覆盖。
- 新增 `testSynchronousAgentFeedbackSurvivesHeldPressIncludingRunningToInterrupted`：在
  `onTriggerAgent` 内同步调用 `setAgentFeedback`，不松开按键即断言 Mock LED 是新值；
  覆盖空闲→排队（40）和运行中→中断（20），松开后保持且不会重复触发。使用注入时钟，无 sleep。
- 先运行该测试确认原实现失败两次（实际 0/127，期望 40/20），再修复；全量 Swift 测试现为
  82 条通过。19 条 BuildWorkflowTests、命令校验、diff 检查、compileall、workflow help、
  App build 与原生 smoke 均通过，无新增编译警告。
- TODO 记录 `OSStatus -304` 已观察到的启动/退出/重开条件，明确尚非稳定复现及原因未知；
  R1 增加 CoreMIDI 连接快照与输入批次回调到达顺序的实机验证。
- `MonitorEvent` 反馈送达状态及学习中替换配置的可见事件已写入 WP2 要求/TODO，本次不实现。
- 本次没有更改视图；没有重复原生界面手动操作，按住期间的 LED 行为由上述会话闭环测试验证。
