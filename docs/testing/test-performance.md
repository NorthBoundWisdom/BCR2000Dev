# 测试耗时优化记录

> 续作更新：新默认 runner 的 8 worker 墙钟中位数 8.6 s（原始基线 23.6 s），
> 1 worker 墙钟 24.7 s、原生用例合计 20.569 s；完整 695 例在 3×默认、2、1 worker 均为 0 失败。
> 下方 P0–P4 及“未完成”是当时的历史结论，后续结果见 P6/P5；原直接 SwiftPM 逐例命令保留对照。
> 上一轮 SurfacePlugins“150 例全部通过”的漏检已在本轮发现并更正，详见末尾审计更正。

## P0 基线

测量命令：`swift test --build-path build/swiftpm --parallel --num-workers 1 --xunit-output build/timings/xunit.xml`。

687 例，失败 0，跳过 0；xunit 用例合计 111.278 s，中位数 0.065 s；命令墙钟 129.17 s。

SwiftPM parallel xunit 按单例子进程计时，包含每次 XCTest 装载成本；与 XCTest 进程内用例时间分开比较。

| 类 | 例数 | 基线合计 s | 中位数 s |
|---|---:|---:|---:|
| BCRAgentConsoleTests.PresetRestoreSafetyTests | 37 | 11.657 | 0.252 |
| BCRAgentConsoleTests.LockedPresetDisplayTests | 21 | 6.515 | 0.208 |
| BCRAgentConsoleTests.HardwareStartupTests | 10 | 5.567 | 0.521 |
| BCRProviderAdapterTests.ProviderModuleTests | 13 | 5.336 | 0.420 |
| BCRProviderAdapterTests.SharedSurfaceScenarioTests | 4 | 5.295 | 1.357 |
| BCRAgentConsoleTests.MonotonicReceiptTests | 5 | 4.274 | 0.737 |
| BCRProviderAdapterTests.EventRetentionTests | 3 | 3.793 | 0.168 |
| BCRAgentConsoleTests.OutputControllerTests | 17 | 3.617 | 0.069 |
| BCRAgentConsoleTests.HardwareConnectionStatusTests | 3 | 2.751 | 0.827 |
| BCRAgentCoreTests.CodexSessionIntegrationTests | 12 | 2.613 | 0.123 |
| BCRProviderAdapterTests.SharedRuntimeMCPTests | 5 | 2.567 | 0.436 |
| BCRAgentCoreTests.CodexApprovalGateTests | 7 | 2.515 | 0.059 |
| BCRAgentCoreTests.CodexProcessSupervisorTests | 12 | 2.200 | 0.115 |
| BCRAgentConsoleTests.SurfaceAgentIntentTests | 5 | 2.116 | 0.236 |
| BCRAgentConsoleTests.ConfigurationPersistenceTests | 14 | 2.062 | 0.184 |
| BCRAgentConsoleTests.IntegrationMIDIFixtureTests | 2 | 1.932 | 0.966 |
| BCRAgentCoreTests.SurfaceSessionTests | 30 | 1.890 | 0.061 |
| BCRAgentConsoleTests.DeviceDisplayTests | 4 | 1.745 | 0.215 |
| BCRAgentConsoleTests.PresetAlignmentFlowTests | 7 | 1.671 | 0.224 |
| BCRProviderAdapterTests.SurfaceControlHoldTests | 13 | 1.555 | 0.086 |
| BCRAgentConsoleTests.CodexAgentControllerTests | 10 | 1.536 | 0.146 |
| BCRAgentCoreTests.MCPTests | 24 | 1.528 | 0.063 |
| BCRAgentCoreTests.EncoderPrecisionTests | 16 | 1.318 | 0.062 |
| BCRProviderAdapterTests.SurfaceControlRegressionTests | 11 | 1.290 | 0.084 |
| BCRAgentConsoleTests.HardwarePressAnimationTests | 3 | 1.230 | 0.391 |
| BCRAgentConsoleTests.AgentLEDBlinkTests | 3 | 1.103 | 0.344 |
| BCRAgentConsoleTests.MIDIEndpointSettingsTests | 6 | 1.060 | 0.175 |
| BCRAgentCoreTests.SurfaceEngineTests | 18 | 1.048 | 0.058 |
| BCRAgentConsoleTests.SSEStreamTests | 8 | 0.953 | 0.103 |
| BCRProviderDomainTests.SimulationTests | 15 | 0.886 | 0.058 |
| BCRAgentConsoleTests.LEDDisplayTests | 2 | 0.859 | 0.430 |
| BCRAgentCoreTests.PresetAlignmentTests | 10 | 0.785 | 0.074 |
| BCRAgentConsoleTests.WindowTitlebarTests | 5 | 0.784 | 0.152 |
| BCRAgentConsoleTests.HardwareButtonFunctionTests | 4 | 0.772 | 0.193 |
| BCRProviderAdapterTests.SurfaceControlTests | 8 | 0.728 | 0.080 |
| BCRAgentConsoleTests.BCRDisplayModelTests | 12 | 0.724 | 0.060 |
| BCRAgentConsoleTests.MCPHTTPServerTests | 8 | 0.715 | 0.078 |
| BCRAgentConsoleTests.WorkspacePanelSettingsTests | 5 | 0.691 | 0.063 |
| BCRAgentConsoleTests.PresetBackupStoreTests | 8 | 0.674 | 0.068 |
| BCRAgentCoreTests.MotionSafetyTests | 11 | 0.665 | 0.060 |
| BCRAgentCoreTests.PersistenceValidationTests | 11 | 0.660 | 0.060 |
| BCRAgentCoreTests.FunctionSystemTests | 10 | 0.625 | 0.062 |
| BCRAgentConsoleTests.WebSocketParameterAdapterTests | 4 | 0.602 | 0.149 |
| BCRAgentCoreTests.PresetDocumentSafetyTests | 6 | 0.589 | 0.068 |
| BCRAgentCoreTests.CodexProcessIntegrationTests | 6 | 0.579 | 0.095 |
| BCRAgentConsoleTests.MIDIInitializationTests | 5 | 0.535 | 0.063 |
| BCRAgentConsoleTests.ConfigurationPresetTests | 2 | 0.519 | 0.259 |
| BCRPluginHostTests.MockAgentHostTests | 8 | 0.517 | 0.062 |
| BCRAgentCoreTests.LocalizationTests | 8 | 0.494 | 0.061 |
| BCRProviderAdapterTests.SimulationConfigurationTests | 6 | 0.485 | 0.082 |
| BCRProviderDomainTests.ConsoleContractTests | 7 | 0.485 | 0.063 |
| BCRAgentConsoleTests.OffscreenPresentationTests | 4 | 0.476 | 0.136 |
| BCRAgentCoreTests.SurfaceConfigurationTests | 8 | 0.469 | 0.058 |
| BCRAgentCoreTests.CodexProtocolTests | 7 | 0.456 | 0.062 |
| BCRAgentConsoleTests.LanguagePreferencesTests | 5 | 0.445 | 0.063 |
| BCRAgentCoreTests.OSCCodecTests | 7 | 0.424 | 0.060 |
| BCRAgentCoreTests.HardwareMapTests | 7 | 0.409 | 0.058 |
| BCRAgentConsoleTests.FunctionEditorTests | 2 | 0.386 | 0.193 |
| BCRAgentConsoleTests.SevenSegmentDisplayTests | 5 | 0.384 | 0.060 |
| BCRAgentCoreTests.BehaviorTraceTests | 6 | 0.384 | 0.063 |
| BCRAgentCoreTests.FeedbackTransportEvidenceTests | 6 | 0.363 | 0.061 |
| BCRAgentCoreTests.LEDRingTests | 6 | 0.350 | 0.058 |
| BCRAgentCoreTests.MIDIModelsTests | 6 | 0.346 | 0.058 |
| BCRProviderAdapterTests.HardwareSurfaceControlTests | 5 | 0.326 | 0.065 |
| BCRAgentCoreTests.SurfaceProgramsTests | 5 | 0.307 | 0.061 |
| BCRProviderAdapterTests.ProviderHardwareVisibilityTests | 1 | 0.306 | 0.306 |
| BCRAgentCoreTests.ButtonPreviewTests | 5 | 0.304 | 0.061 |
| BCRAgentConsoleTests.ConsoleLayoutTests | 5 | 0.301 | 0.060 |
| BCRAgentCoreTests.MockBCR2000Tests | 5 | 0.295 | 0.059 |
| BCRAgentCoreTests.MIDIEndpointSelectionTests | 5 | 0.289 | 0.058 |
| BCRProviderDomainTests.HardwareRoleCandidateTests | 4 | 0.271 | 0.068 |
| BCRAgentConsoleTests.ConfigurationLibraryTests | 4 | 0.271 | 0.067 |
| BCRAgentConsoleTests.IntegrationTestContextTests | 2 | 0.265 | 0.133 |
| BCRAgentConsoleTests.ConsoleRefreshTests | 1 | 0.264 | 0.264 |
| BCRAgentCoreTests.BuiltInNamePresentationTests | 4 | 0.252 | 0.063 |
| BCRProviderDomainTests.SharedSimulationCompatibilityTests | 4 | 0.242 | 0.059 |
| BCRAgentCoreTests.SharedOutputCompatibilityTests | 4 | 0.242 | 0.060 |
| BCRAgentCoreTests.PluginSurfaceCompatibilityTests | 4 | 0.241 | 0.061 |
| BCRAgentConsoleTests.ParameterDraftTests | 4 | 0.241 | 0.060 |
| BCRAgentCoreTests.CodexSessionStateMachineTests | 4 | 0.238 | 0.059 |
| BCRProviderDomainTests.HardwareRoleReadinessTests | 4 | 0.237 | 0.058 |
| BCRProviderAdapterTests.SurfaceControl13Tests | 3 | 0.236 | 0.075 |
| BCRAgentCoreTests.WorkspacePolicyTests | 4 | 0.235 | 0.059 |
| BCRPluginHostTests.PluginRegistrationTests | 4 | 0.234 | 0.058 |
| BCRAgentCoreTests.BCRPresetEncoderLearningTests | 3 | 0.230 | 0.078 |
| BCRProviderAdapterTests.TimingIsolationEvidenceTests | 1 | 0.226 | 0.226 |
| BCRAgentConsoleTests.OffscreenInteractionPanelTests | 2 | 0.217 | 0.108 |
| BCRAgentConsoleTests.PipedMCPCredentialStoreTests | 3 | 0.189 | 0.062 |
| BCRAgentCoreTests.AgentStateMachineTests | 3 | 0.182 | 0.060 |
| BCRAgentConsoleTests.PresetDumpStreamTests | 3 | 0.181 | 0.060 |
| BCRAgentCoreTests.JSONParameterLinkTests | 3 | 0.177 | 0.059 |
| BCRAgentCoreTests.FeedbackSchedulerTests | 3 | 0.176 | 0.058 |
| BCRAgentConsoleTests.OffscreenActivationGuardTests | 2 | 0.140 | 0.070 |
| BCRAgentCoreTests.HardwareOutputPolicyTests | 2 | 0.134 | 0.067 |
| BCRAgentCoreTests.ConfigurationPresetCoreTests | 2 | 0.125 | 0.063 |
| BCRProviderAdapterTests.SurfaceControlPrincipalsTests | 2 | 0.124 | 0.062 |
| BCRAgentConsoleTests.CoreMIDIAvailabilityTests | 2 | 0.124 | 0.062 |
| BCRAgentCoreTests.AgentCompatibilityTests | 2 | 0.124 | 0.062 |
| BCRAgentCoreTests.HardwareStartupSnapshotTests | 2 | 0.123 | 0.061 |
| BCRAgentCoreTests.SharedSurfaceRegressionTests | 2 | 0.121 | 0.061 |
| BCRAgentCoreTests.AgentCompatibilityFacadeTests | 2 | 0.121 | 0.060 |
| BCRAgentConsoleTests.PresetNamesStreamTests | 2 | 0.120 | 0.060 |
| BCRAgentConsoleTests.FeedbackSettingsTests | 1 | 0.102 | 0.102 |
| BCRAgentCoreTests.CodexSessionCoordinatorTests | 1 | 0.086 | 0.086 |
| BCRProviderAdapterTests.IndependentHardwareRuntimeFixtureTests | 1 | 0.083 | 0.083 |
| BCRAgentConsoleTests.AgentLEDBlinkPatternTests | 1 | 0.074 | 0.074 |
| BCRProviderAdapterTests.HardwareProfileFixtureTests | 1 | 0.070 | 0.070 |
| BCRAgentConsoleTests.ArmPreviewTests | 1 | 0.063 | 0.063 |
| BCRAgentCoreTests.CodexModelCatalogStoreTests | 1 | 0.063 | 0.063 |
| BCRAgentCoreTests.HardwareConfirmationGatewayTests | 1 | 0.062 | 0.062 |
| BCRAgentConsoleTests.OutputTransportRouterTests | 1 | 0.061 | 0.061 |
| BCRAgentConsoleTests.MIDISysExAssemblerTests | 1 | 0.061 | 0.061 |
| BCRAgentConsoleTests.PresetNumberEvidenceTests | 1 | 0.061 | 0.061 |
| BCRAgentCoreTests.ParameterChangeAccumulatorTests | 1 | 0.059 | 0.059 |

## P1 时间依赖与默认值

`HostTime` 将单调时间读取和可取消 sleep 一起注入；`ConsoleTiming` 分开有限后台工作和呈现时钟。
`.immediate` 只立即完成后台工作，周期任务不会忙循环。需要证明时长的测试使用 `ManualHostTime`。
生产构造器无需改动。`ConsoleTimingTests.testProductionTimingDefaultsPreserveCalibratedDurations`
逐项验证如下旧常量（也验证两个默认时钟读取系统 uptime）：

| 调用点（函数） | 默认时长/时间源 | 用途 |
|---|---|---|
| ConsoleViewModel session.onChange | 16 ms | 合并界面刷新 |
| noteDeviceActivity | 120 ms | MIDI 活动灯 |
| showDeviceInput / displayContent | uptime；值 0.8 s，按钮 0.5 s | 显示保持 |
| scheduleNoticeDismissal | 6 s | 信息提示消失 |
| offerHardwareConnection | 300 ms | 连接稳定期 |
| buttonActivity release | 最少 80 ms（减去已按住时长） | 短按可见 |
| buttonActivity counter | 180 ms | 计数脉冲按压 |
| showAgentState / updateBlinkTimer | uptime / 50 ms | Agent 闪灯 |
| OutputController.start | 20 ms | 输出门 tick |
| WebSocketParameterAdapter.stop | 200 ms | 优雅关闭超时 |

新增 `testConnectionOfferWaitsForTheFullStablePeriod` 验证 299 ms 时不提示、300 ms 时提示；
`testManualSleeperPreservesDeadlineAndCancellation` 验证手动截止点和取消传播。

其余真实计时（本阶段保持原样）：ConsoleViewModel.waitForBackgroundWork 的真实 10 s 防挂死期限；
BCRMockAgentHost 的 25 ms 驱动；ProviderApplication/ProviderService 的 20 ms 驱动；
MCPHTTPServer 的 5 s 请求/握手期限、10 s SSE 心跳和 16 ms 合并；
CodexProcessSupervisor 的 20/10 ms 退出轮询、5 ms 读取轮询和配置化重连退避，CodexRPCClient 的请求期限；
CoreMIDIService 的 100 ms 发现/读取轮询、2 s 预设读取期限；
SurfaceControlAdapter 的注入 hold scheduler；FeedbackSettingsView 的 16 ms 刷新；
SettingsWindow 的 2 s 设置刷新；App 的 100 ms 集成就绪轮询、120 ms 初始化 smoke 等待；
TestOnlyHardwareDevice 的 20 ms 软件交付等待；IntegrationMIDIFixture 的启动配置延迟、
200 ms snapshot/current/memory read、400 ms write startup、每 30 帧 20 ms。

## P2 等待迁移审计

无断言删除或放宽；无用例删除；循环规模均未缩小。

- IntegrationMIDIFixture 新增 `time`，默认 HostTime.live，200/400/20 ms 保持；仅单元测试显式 immediate。
  默认值由 `IntegrationMIDIFixtureTests.testDefaultFixtureCadenceMatchesNativeAcceptance` 验证。
- ConsoleTiming.intentNow 将既有 SurfaceSession 的 Date 注入接口传到构造边界，默认 Date.now；
  `testProductionTimingDefaultsPreserveCalibratedDurations` 同时验证默认墙钟。SurfaceAgentIntent 的 260 ms
  去抖间隔改为在此时钟推进 0.26 s，数值与含义不变。
- AgentLEDBlink 的稳态无流量 300 ms 改为手动推进 0.3 s；先推进 0.2 s 观察 attention 的半周期。
- HardwarePressAnimation 的 240/100 ms 保持/无二次按下改为推进同样时间；短按 80 ms 和脉冲 180 ms
  改为手动达到既有截止点。
- HardwareStartup 的 30 ms 排空保护改为手动时间加 actor 交接（替身仍明确持有被取消 dump）；
  80 ms 启动等待改为 waitUntil(!startingMIDI)。没有减少证明窗口。
- PresetRestoreSafety 的 350 ms 重连保护改为手动推进同样时间，dump 仍由 continuation 持有。
- LEDDisplay / DeviceDisplay / LockedPresetDisplay 中的实际 0.5/0.8 s 显示保持、120 ms 活动灯改为手动推进原时长。
- MonotonicReceipt 的 110 ms 固定等待删除：原有 heartbeat 计数增长条件继续等待，并保留前后 tick 和所有断言。
  0.65 s 同步阻塞的两个真实 IO 测试保留；它们证明 IO 回调在 MainActor 不可用时也记录原始时间/队列溢出。
- CodexApprovalGate 的 2 s sleep 改为传 requestedAt + 2 s，原 1 s 过期窗口及异常类型断言不变。
- SSE backpressure 的每轮 30 ms sleep 改为手动推进 30 ms。新增 eventTime 只注入合并等待，默认 16 ms，
  由 `SSEStreamTests.testDefaultSSECoalescingDelayIsUnchanged` 验证；50 参数 × 5 轮和全部关闭/审计断言保留。

补充：MonotonicReceipt 的 110 ms 也是 ping cadence 的条件，不能直接删掉；现将既有 adapter 和
runtime 的 monotonic 注入点设为同一个手动时间，每次推进 0.11 s，再由原有计数条件等待 IO。
真实堵塞 IO 的两例继续使用真实 monotonic。原生离屏 connection UI（默认 fixture 节奏）已通过
连接 decline/read、preview、write/readback、restore、discard 确认/取消；桌面无前台抢占。

## P3 计算热点

`sample`（1 ms 采样、1 s）保存在 ignored `build/timings/{provider,output}.sample.txt`。
Provider 栈主要落在 RemoteRegistry.validateReplacement 反复生成不可变工具 Schema、
ProviderEventJournal.append 构造 ISO8601 formatter；Output 10000 tick 栈也命中这两处。

- SurfacePlugins 的 Robot/Chassis/Output binding 缓存不可变工具描述，replacement 的完整相等校验继续执行；
  不缓存运行状态，不改变工具名、Schema 或错误。`ImmutableDescriptorTests.testDescriptorsDoNotCaptureInstanceOrLifecycleState`
  验证跨实例/生命周期声明一致，错 instance 路由仍拒绝。
- BCR journal 在 MainActor 内复用默认 ISO8601 formatter。新测试
  `ConsoleContractTests.testJournalRetainsDefaultUTCFormatAndFreshTimestampForEachAppend` 验证 UTC 字符串、
  每次最新墙钟、单调时间和 sequence。没有关闭 Provider 1.0 SSE 或跳过 idle 状态更新。
- ProviderContractSchema 原先每次 definition/tool 都重读并解码完整资源；现缓存进程内不可变资源和 JSON。
  `testCachedProviderContractMatchesPublishedResource` 对照发布的原始文件验证内容。
- SharedSurfaceScenarioTests 缓存不变档案/身份，在 reset 后失效。每个 host 保存上一步完整观察作为下一步
  before；每步一次 after 完整 fingerprint，并复用 snapshot 操作的结果。完整原子性比较（journal、全部
  108 个控件、参数、Mock 输入/显示等）、fixture 驱动及全部 checks/XCTAssert 均保留。
- 2000 idle ticks 和 10000 ready telemetry ticks 保持原规模、时长/sequence/trace/事件保持断言全部不变。

## P4 子进程与 IO

ProviderModule/SharedRuntimeMCP 未见固定 sleep、子进程或超时消耗；慢在反复读取 Provider 合同。
P3 缓存后，进程内分别由 4.175/2.074 s 变为 0.374/0.030 s（最终测量）。
Codex 包含真实 Python/sh 启动、管道 EOF 排空、退出轮询和退避。保持真实 IO 与原 stop/kill 期限。

- CodexProcessSupervisor 的 restartSleep 默认仍是 Task.sleep(configured backoff)，测试可手动推进。
  `testProductionProcessTimeoutDefaultsAreUnchanged` 验证原 2000/250/3000 ms 配置默认值。
- normal-exit 原 150 ms 无重启窗口手动推进，原事件数组断言保留，并新增“无待决 backoff”断言。
- stop-during-backoff 原 250 ms 无重启窗口手动推进，同时额外跨过完整 2 s backoff；等待 termination
  handler（含 restart decision）完成后再断言。没有缩短 backoff，也没有减少重启次数。
- final-line 原 80 ms 等待换成 waitUntilAsync(!isRunning)，仍证明退出后的尾行不会丢失。
- Controller 的 20 ms 清理等待换成等待实际 start/interrupt/approval task 完成；30 ms queued 等待换成
  等待 coordinator 的 activeThread 状态（线程已建立、turn 回复仍在途）。保留所有状态/错误/另一槽位断言。
- 原有 2/5/10/20 ms 状态轮询不是固定完成假设；真实 EOF/进程退出/网络输入到达后立即返回。
  真实分片 UTF-8 的 shell 50 ms 与 delayed_hold 的 Python 200 ms 保留，继续覆盖实际跨读取/在途 RPC。

## 最终对比（同机、同一计时口径）

| 指标 | 优化前 | 优化后 | 结果 |
|---|---:|---:|---|
| XCTest 进程内用例合计 | 65.686 s | 20.354 s | 下降 69.0%，≤30 s |
| XCTest 中位数 | 0.003 s | 0.002 s | |
| 指定 SwiftPM 串行 xunit 合计 | 111.278 s | 67.091 s | **未达到 ≤30 s**；包含逐例进程启动 |
| SwiftPM xunit 中位数 | 0.065 s | 0.064 s | |
| 用例数 | 687 | 695 | 新增 8，无删除 |

进程内计时命令：`swift test --skip-build --build-path build/swiftpm`，随后
`python3 tools/test_timings.py --xctest-log build/timings/final-inprocess.log --json build/timings/final-native.json`。
指定口径由 `BCR_TEST_WORKERS=1 python3 configs/macos_workflow.py test` 调用相同的 SwiftPM
`--parallel --num-workers 1 --xunit-output` 命令；报告用 `tools/test_timings.py` 原样读取，未扣除启动成本。

XCTest 原生日志前后均有一个既有硬件 opt-in skip：`testRealCoreMIDIQualificationIsOptIn`，未设置实机环境变量。
SwiftPM parallel xunit 没有把这个既有 skip 写成 `<skipped>`，所以其汇总显示 0；不以该显示声称跑过硬件。

### 按类完整对比（秒）

| 类 | 前/后例数 | 原生前 | 原生后 | xunit前 | xunit后 |
|---|---:|---:|---:|---:|---:|
| BCRAgentConsoleTests.PresetRestoreSafetyTests | 37/37 | 8.699 | 3.928 | 11.657 | 7.185 |
| BCRProviderAdapterTests.SharedSurfaceScenarioTests | 4/4 | 4.991 | 2.717 | 5.295 | 2.971 |
| BCRAgentConsoleTests.HardwareStartupTests | 10/10 | 4.807 | 0.094 | 5.567 | 0.896 |
| BCRAgentConsoleTests.LockedPresetDisplayTests | 21/21 | 4.795 | 0.173 | 6.515 | 1.951 |
| BCRProviderAdapterTests.ProviderModuleTests | 13/13 | 4.175 | 0.374 | 5.336 | 1.447 |
| BCRAgentConsoleTests.MonotonicReceiptTests | 5/5 | 3.955 | 3.224 | 4.274 | 3.587 |
| BCRProviderAdapterTests.EventRetentionTests | 3/3 | 3.594 | 0.887 | 3.793 | 1.074 |
| BCRAgentConsoleTests.HardwareConnectionStatusTests | 3/3 | 2.498 | 0.038 | 2.751 | 0.285 |
| BCRAgentConsoleTests.OutputControllerTests | 17/17 | 2.482 | 0.534 | 3.617 | 1.667 |
| BCRProviderAdapterTests.SharedRuntimeMCPTests | 5/5 | 2.074 | 0.030 | 2.567 | 0.428 |
| BCRAgentCoreTests.CodexApprovalGateTests | 7/7 | 2.061 | 0.000 | 2.515 | 0.408 |
| BCRAgentCoreTests.CodexSessionIntegrationTests | 12/12 | 1.953 | 2.046 | 2.613 | 2.707 |
| BCRAgentConsoleTests.IntegrationMIDIFixtureTests | 2/3 | 1.820 | 0.023 | 1.932 | 0.211 |
| BCRAgentConsoleTests.SurfaceAgentIntentTests | 5/5 | 1.701 | 0.161 | 2.116 | 0.587 |
| BCRAgentCoreTests.CodexProcessSupervisorTests | 12/13 | 1.450 | 0.887 | 2.200 | 1.756 |
| BCRAgentConsoleTests.DeviceDisplayTests | 4/4 | 1.443 | 0.025 | 1.745 | 0.359 |
| BCRAgentConsoleTests.PresetAlignmentFlowTests | 7/7 | 1.097 | 0.315 | 1.671 | 0.913 |
| BCRAgentConsoleTests.ConfigurationPersistenceTests | 14/14 | 1.080 | 0.057 | 2.062 | 1.127 |
| BCRAgentConsoleTests.HardwarePressAnimationTests | 3/3 | 0.970 | 0.023 | 1.230 | 0.274 |
| BCRAgentConsoleTests.AgentLEDBlinkTests | 3/3 | 0.878 | 0.041 | 1.103 | 0.271 |
| BCRAgentConsoleTests.CodexAgentControllerTests | 10/10 | 0.850 | 0.767 | 1.536 | 1.436 |
| BCRProviderAdapterTests.SurfaceControlHoldTests | 13/13 | 0.730 | 0.727 | 1.555 | 1.559 |
| BCRAgentConsoleTests.LEDDisplayTests | 2/2 | 0.725 | 0.005 | 0.859 | 0.169 |
| BCRAgentConsoleTests.MIDIEndpointSettingsTests | 6/6 | 0.597 | 0.028 | 1.060 | 0.523 |
| BCRProviderAdapterTests.SurfaceControlRegressionTests | 11/11 | 0.570 | 0.346 | 1.290 | 1.084 |
| BCRAgentConsoleTests.HardwareButtonFunctionTests | 4/4 | 0.470 | 0.014 | 0.772 | 0.358 |
| BCRAgentConsoleTests.SSEStreamTests | 8/9 | 0.445 | 0.167 | 0.953 | 0.750 |
| BCRAgentCoreTests.EncoderPrecisionTests | 16/16 | 0.364 | 0.324 | 1.318 | 1.271 |
| BCRAgentConsoleTests.ConfigurationPresetTests | 2/2 | 0.355 | 0.015 | 0.519 | 0.185 |
| BCRAgentConsoleTests.WebSocketParameterAdapterTests | 4/4 | 0.348 | 0.363 | 0.602 | 0.637 |
| BCRAgentConsoleTests.WorkspacePanelSettingsTests | 5/5 | 0.339 | 0.009 | 0.691 | 0.363 |
| BCRAgentCoreTests.CodexProcessIntegrationTests | 6/6 | 0.254 | 0.227 | 0.579 | 0.597 |
| BCRProviderAdapterTests.ProviderHardwareVisibilityTests | 1/1 | 0.237 | 0.020 | 0.306 | 0.083 |
| BCRAgentConsoleTests.FunctionEditorTests | 2/2 | 0.235 | 0.007 | 0.386 | 0.178 |
| BCRAgentCoreTests.PresetDocumentSafetyTests | 6/6 | 0.234 | 0.230 | 0.589 | 0.590 |
| BCRProviderAdapterTests.SurfaceControlTests | 8/8 | 0.215 | 0.209 | 0.728 | 0.723 |
| BCRAgentConsoleTests.MIDIInitializationTests | 5/5 | 0.205 | 0.020 | 0.535 | 0.366 |
| BCRAgentConsoleTests.ConsoleRefreshTests | 1/1 | 0.187 | 0.017 | 0.264 | 0.099 |
| BCRProviderAdapterTests.TimingIsolationEvidenceTests | 1/1 | 0.162 | 0.167 | 0.226 | 0.226 |
| BCRAgentCoreTests.PresetAlignmentTests | 10/10 | 0.156 | 0.156 | 0.785 | 0.779 |
| BCRAgentConsoleTests.PresetBackupStoreTests | 8/8 | 0.152 | 0.042 | 0.674 | 0.571 |
| BCRAgentConsoleTests.MCPHTTPServerTests | 8/8 | 0.151 | 0.038 | 0.715 | 0.591 |
| BCRAgentConsoleTests.LanguagePreferencesTests | 5/5 | 0.122 | 0.008 | 0.445 | 0.340 |
| BCRAgentConsoleTests.IntegrationTestContextTests | 2/2 | 0.116 | 0.003 | 0.265 | 0.147 |
| BCRProviderAdapterTests.SimulationConfigurationTests | 6/6 | 0.109 | 0.108 | 0.485 | 0.490 |
| BCRAgentCoreTests.SurfaceSessionTests | 30/30 | 0.093 | 0.038 | 1.890 | 1.833 |
| BCRAgentConsoleTests.OffscreenInteractionPanelTests | 2/2 | 0.092 | 0.090 | 0.217 | 0.192 |
| BCRAgentConsoleTests.WindowTitlebarTests | 5/5 | 0.062 | 0.065 | 0.784 | 0.838 |
| BCRProviderAdapterTests.SurfaceControl13Tests | 3/3 | 0.045 | 0.041 | 0.236 | 0.233 |
| BCRAgentCoreTests.BCRPresetEncoderLearningTests | 3/3 | 0.044 | 0.044 | 0.230 | 0.228 |
| BCRAgentCoreTests.CodexProtocolTests | 7/7 | 0.042 | 0.038 | 0.456 | 0.459 |
| BCRPluginHostTests.MockAgentHostTests | 8/8 | 0.042 | 0.039 | 0.517 | 0.511 |
| BCRProviderDomainTests.ConsoleContractTests | 7/9 | 0.039 | 0.050 | 0.485 | 0.587 |
| BCRAgentCoreTests.MCPTests | 24/24 | 0.039 | 0.035 | 1.528 | 1.521 |
| BCRAgentConsoleTests.FeedbackSettingsTests | 1/1 | 0.033 | 0.028 | 0.102 | 0.098 |
| BCRAgentConsoleTests.SevenSegmentDisplayTests | 5/5 | 0.030 | 0.028 | 0.384 | 0.375 |
| BCRAgentCoreTests.CodexSessionCoordinatorTests | 1/1 | 0.030 | 0.034 | 0.086 | 0.092 |
| BCRAgentCoreTests.FunctionSystemTests | 10/10 | 0.024 | 0.019 | 0.625 | 0.619 |
| BCRProviderDomainTests.HardwareRoleCandidateTests | 4/4 | 0.021 | 0.021 | 0.271 | 0.273 |
| BCRAgentCoreTests.BehaviorTraceTests | 6/6 | 0.021 | 0.012 | 0.384 | 0.373 |
| BCRProviderAdapterTests.HardwareSurfaceControlTests | 5/5 | 0.020 | 0.017 | 0.326 | 0.325 |
| BCRProviderAdapterTests.IndependentHardwareRuntimeFixtureTests | 1/1 | 0.019 | 0.018 | 0.083 | 0.082 |
| BCRAgentConsoleTests.OffscreenPresentationTests | 4/4 | 0.016 | 0.018 | 0.476 | 0.463 |
| BCRProviderDomainTests.SimulationTests | 15/15 | 0.016 | 0.016 | 0.886 | 0.887 |
| BCRAgentCoreTests.HardwareOutputPolicyTests | 2/2 | 0.014 | 0.004 | 0.134 | 0.124 |
| BCRAgentCoreTests.LocalizationTests | 8/8 | 0.014 | 0.014 | 0.494 | 0.500 |
| BCRAgentConsoleTests.ConfigurationLibraryTests | 4/4 | 0.009 | 0.009 | 0.271 | 0.276 |
| BCRProviderDomainTests.SharedSimulationCompatibilityTests | 4/4 | 0.009 | 0.009 | 0.242 | 0.244 |
| BCRAgentCoreTests.FeedbackTransportEvidenceTests | 6/6 | 0.008 | 0.006 | 0.363 | 0.360 |
| BCRProviderAdapterTests.HardwareProfileFixtureTests | 1/1 | 0.007 | 0.006 | 0.070 | 0.070 |
| BCRProviderAdapterTests.SurfaceControlPrincipalsTests | 2/2 | 0.006 | 0.006 | 0.124 | 0.127 |
| BCRAgentCoreTests.CodexModelCatalogStoreTests | 1/1 | 0.004 | 0.002 | 0.063 | 0.060 |
| BCRAgentConsoleTests.OffscreenActivationGuardTests | 2/2 | 0.003 | 0.004 | 0.140 | 0.152 |
| BCRAgentCoreTests.AgentStateMachineTests | 3/3 | 0.003 | 0.003 | 0.182 | 0.184 |
| BCRAgentCoreTests.PersistenceValidationTests | 11/11 | 0.003 | 0.003 | 0.660 | 0.660 |
| BCRAgentCoreTests.SurfaceProgramsTests | 5/5 | 0.003 | 0.003 | 0.307 | 0.310 |
| BCRAgentCoreTests.BuiltInNamePresentationTests | 4/4 | 0.003 | 0.003 | 0.252 | 0.251 |
| BCRAgentCoreTests.SharedSurfaceRegressionTests | 2/2 | 0.003 | 0.002 | 0.121 | 0.119 |
| BCRAgentCoreTests.AgentCompatibilityTests | 2/2 | 0.002 | 0.002 | 0.124 | 0.129 |
| BCRAgentCoreTests.ConfigurationPresetCoreTests | 2/2 | 0.002 | 0.002 | 0.125 | 0.125 |
| BCRAgentCoreTests.HardwareStartupSnapshotTests | 2/2 | 0.002 | 0.002 | 0.123 | 0.124 |
| BCRAgentCoreTests.ButtonPreviewTests | 5/5 | 0.002 | 0.002 | 0.304 | 0.303 |
| BCRAgentCoreTests.PluginSurfaceCompatibilityTests | 4/4 | 0.001 | 0.001 | 0.241 | 0.242 |
| BCRAgentCoreTests.HardwareConfirmationGatewayTests | 1/1 | 0.001 | 0.001 | 0.062 | 0.062 |
| BCRAgentCoreTests.HardwareMapTests | 7/7 | 0.001 | 0.001 | 0.409 | 0.410 |
| BCRAgentCoreTests.SurfaceConfigurationTests | 8/8 | 0.001 | 0.001 | 0.469 | 0.469 |
| BCRAgentCoreTests.AgentCompatibilityFacadeTests | 2/2 | 0.001 | 0.001 | 0.121 | 0.142 |
| BCRPluginHostTests.PluginRegistrationTests | 4/4 | 0.001 | 0.001 | 0.234 | 0.232 |
| BCRAgentConsoleTests.PresetDumpStreamTests | 3/3 | 0.001 | 0.001 | 0.181 | 0.183 |
| BCRAgentConsoleTests.PipedMCPCredentialStoreTests | 3/3 | 0.001 | 0.001 | 0.189 | 0.191 |
| BCRAgentCoreTests.MockBCR2000Tests | 5/5 | 0.001 | 0.001 | 0.295 | 0.295 |
| BCRProviderDomainTests.HardwareRoleReadinessTests | 4/4 | 0.001 | 0.001 | 0.237 | 0.239 |
| BCRAgentCoreTests.WorkspacePolicyTests | 4/4 | 0.000 | 0.000 | 0.235 | 0.237 |
| BCRAgentConsoleTests.CoreMIDIAvailabilityTests | 2/2 | 0.000 | 0.000 | 0.124 | 0.120 |
| BCRAgentConsoleTests.BCRDisplayModelTests | 12/12 | 0.000 | 0.000 | 0.724 | 0.723 |
| BCRAgentConsoleTests.PresetNamesStreamTests | 2/2 | 0.000 | 0.000 | 0.120 | 0.121 |
| BCRAgentCoreTests.MIDIModelsTests | 6/6 | 0.000 | 0.000 | 0.346 | 0.348 |
| BCRAgentConsoleTests.OutputTransportRouterTests | 1/1 | 0.000 | 0.000 | 0.061 | 0.060 |
| BCRAgentCoreTests.SharedOutputCompatibilityTests | 4/4 | 0.000 | 0.000 | 0.242 | 0.243 |
| BCRAgentCoreTests.MotionSafetyTests | 11/11 | 0.000 | 0.000 | 0.665 | 0.668 |
| BCRAgentCoreTests.ParameterChangeAccumulatorTests | 1/1 | 0.000 | 0.000 | 0.059 | 0.058 |
| BCRAgentConsoleTests.ConsoleTimingTests | 0/3 | 0.000 | 0.017 | 0.000 | 0.221 |
| BCRAgentConsoleTests.AgentLEDBlinkPatternTests | 1/1 | 0.000 | 0.000 | 0.074 | 0.060 |
| BCRAgentConsoleTests.MIDISysExAssemblerTests | 1/1 | 0.000 | 0.000 | 0.061 | 0.061 |
| BCRAgentCoreTests.FeedbackSchedulerTests | 3/3 | 0.000 | 0.000 | 0.176 | 0.177 |
| BCRAgentCoreTests.LEDRingTests | 6/6 | 0.000 | 0.000 | 0.350 | 0.353 |
| BCRAgentConsoleTests.ParameterDraftTests | 4/4 | 0.000 | 0.000 | 0.241 | 0.241 |
| BCRAgentConsoleTests.ConsoleLayoutTests | 5/5 | 0.000 | 0.000 | 0.301 | 0.301 |
| BCRAgentCoreTests.MIDIEndpointSelectionTests | 5/5 | 0.000 | 0.000 | 0.289 | 0.292 |
| BCRAgentCoreTests.SurfaceEngineTests | 18/18 | 0.000 | 0.000 | 1.048 | 1.054 |
| BCRAgentConsoleTests.ArmPreviewTests | 1/1 | 0.000 | 0.000 | 0.063 | 0.063 |
| BCRAgentConsoleTests.PresetNumberEvidenceTests | 1/1 | 0.000 | 0.000 | 0.061 | 0.062 |
| BCRAgentCoreTests.OSCCodecTests | 7/7 | 0.000 | 0.000 | 0.424 | 0.422 |
| BCRAgentCoreTests.CodexSessionStateMachineTests | 4/4 | 0.000 | 0.000 | 0.238 | 0.236 |
| BCRAgentCoreTests.JSONParameterLinkTests | 3/3 | 0.000 | 0.000 | 0.177 | 0.179 |

### 新增用例与超 1 s 例外

- P1：ConsoleTimingTests 3 例（默认常量/时钟、手动 deadline/取消、300 ms 连接边界）。
- P2：fixture 默认节奏、SSE 默认合并时长，各 1 例。
- P3：journal UTC/每次时间、缓存合同对照发布资源，各 1 例。
- P4：进程 stop/backoff 默认值 1 例。
- Shared package 另新增 ImmutableDescriptorTests 1 例，不计入 BCR 的 695。

保留超过 1 s 的三例（没有缩小常量）：
- MonotonicReceiptTests.testRealIOReceiptRetainsItsAgeWhileMainActorIsBlocked：原生 1.478 s；两个真实 loopback 协议各阻塞 0.65 s，证明生产接收时间戳不会随 MainActor 延迟刷新。
- MonotonicReceiptTests.testBoundedRealReceiveOverflowIsVisibleAndClosesWithoutAnOwnerStop：原生 1.463 s；两个协议各阻塞 0.65 s，使实际后台接收越过容量并验证自动关闭。
- CodexSessionIntegrationTests.testProtocolAndStateMachineSoak：原生 1.051 s；保留既有默认 1 s 真实子进程 soak，未缩小时间或循环。

### 未完成与边界

- **未声称全部性能验收达标**：原生测试体 ≤30 s 已满足；指定 SwiftPM xunit 合计仍 67.091 s，默认并行墙钟减半也尚未满足。
- 主要剩余差额是 SwiftPM 逐例 XCTest 进程启动。保留现有 `swift test --parallel`、build/cache 与 xunit 验证流程，没有改变测量口径或以减少用例/循环隐藏它。
- P5 的 XTouch 优化/独立测量未启动：遵守 BCR 全部达标后再做的顺序；XTouch 已按开工要求 status/fetch，保持干净无提交。
- SurfacePlugins 的改动是 BCR P3 直接依赖热点修复；该阶段验证额外测得 Python 94 例 12.531 s、Pipe 10 例 0.047 s，全通过，未改 Python 测试或开展 P5 优化。
- 未运行实机 opt-in；未创建分支/worktree、stash/reset、tag/release 或 push。
- SurfacePlugins 本地锁 revision 尚未推送，干净新机需由用户决定发布，或按现有约定用 acquisition source 获取提交。

## 最终验证与提交

| 命令 | 结果 |
|---|---|
| `python3 configs/macos_workflow.py test` 默认 8 worker，连续三遍（独占 SwiftPM） | 每遍 695 例，0 失败；17.4 / 15.4 / 15.6 s |
| `BCR_TEST_WORKERS=2 python3 configs/macos_workflow.py test` | 695 例，0 失败；46.6 s |
| `BCR_TEST_WORKERS=1 python3 configs/macos_workflow.py test` | 695 例，0 失败；70.4 s；xunit 用例合计 67.091 s |
| `python3 -m unittest discover -s Tests/BuildWorkflowTests` | 113 例，0 失败 |
| `PYTHONPATH=Clients/Python python3 -m unittest discover -s Clients/Python/tests` | 6 例，0 失败 |
| `python3 configs/check_domain_boundaries.py` | 20 个模块边界通过 |
| `python3 configs/format_repo.py --all --check` | 通过 |
| `python3 configs/validate_repo_commands.py .` / `python3 -m compileall -q configs` | 通过 |
| `python3 tools/mcp_integration.py` | 两个 MCP 协议版本、鉴权/Origin/保护/原子操作通过，离屏桌面审计通过 |
| `python3 configs/package_provider.py --output build/ci-surface-provider --configuration debug` | 软件交付件成功 |
| `python3 configs/verify_surface_control_transport.py --artifact build/ci-surface-provider --output build/ci-surface-transport` | 17 项通过，0 失败；2 个历史 SDK archive 缺失项按脚本原有逻辑 skip |
| `python3 configs/macos_workflow.py build` / `smoke` | 构建与中英文 1200×760 离屏原生启动通过 |
| `python3 tools/mcp_integration.py --connection-fixture --offscreen --script tools/verify_connection_ui.py --configuration-write` | 默认 fixture 节奏下连接/对齐/写入回读/恢复/丢弃确认通过 |
| `git diff --check` | 通过 |

默认并行基线 23.6 s，优化后独占测量三遍中位数 15.6 s，下降 **33.9%**，尚未减半。
早先额外三遍也均 0 失败；其中一次包含另一条串行测量等待 SwiftPM 锁的时间（36.8 s），
明确不用于性能比较，因此补做上表的连续三遍独占测量。没有对失败用例做重试或跳过来通过稳定性检查。

已有输出目录被保存在 ignored `build/timings/preexisting-*` 后再执行要求的 fresh-output 打包命令，
没有覆盖旧交付件。transport 的两个历史 SDK skip 分别为 1.1.0、1.2.0，原因是 frozen archive 不在本机；
不是本轮新加的 skip。真机 opt-in 与历史 SDK 两类未验证能力均不算作已验证。

全部提交仅在本地 `main`：

- BCR P0 `13fb1e4` — `test: add xunit timing reports and record baseline`
- BCR P1 `e5eceff` — `refactor(ui): inject host time without changing production cadence`
- BCR P2 `eb09671` — `test: drive fixture and duration assertions with injected time`
- BCR P3 `edf95a5` — `perf: cache immutable contracts and journal timestamp formatting`
- BCR P4 `9696170` — `test(codex): await process state and inject restart backoff sleep`
- SurfacePlugins P3 `bd61126225885a12bc162063309292ec5d404945` — `perf: reuse immutable robot chassis and output tool descriptors`
- XTouch：无提交、无工作区改动。

上一轮报告曾写“SurfacePlugins Swift 150 例、Python SDK 94 例、Pipe 10 例均通过”；其中 Swift 项有漏检，见末尾更正。`configs/check_boundaries.py`
和 `git diff --check` 通过。各仓库开工 status/fetch 完成，始终在各自 main，没有推送。

## 继续优化：原生 XCTest 批量 runner（P6，2026-11-15）

上文为 P0–P4 当时的记录。用户确认此前由其本人推送，并授权继续尝试，等待 owner 一并审计。
本阶段不修改 Swift 生产代码、Swift 测试、断言、循环次数或时长常量；改进发生在测试启动层。

`configs/macos_workflow.py test` 默认由 SwiftPM `test list` 构建并发现完整用例清单；
查询当前产物目录后，通过 Xcode 原生 `xctest -XCTest` 执行同包测试类批次。
每个类在一个批次内，按用例数量分配批次，最多使用 BCR_TEST_WORKERS 个并发进程。
默认 8 worker 将 695 次原生启动降到 31 次；1 worker 使用 5 个包批次。
这没有删除用例或用更少业务操作替代测试。31/5 是启动批次数，不是缩小的测试循环常量。

新 runner 的完整性约束：

- 发现模块必须恰好等于 manifest 中的全部测试模块，发现的用例 ID 不得重复或使用未知格式。
- 每批实际 started/completed 的 ID 多重集必须分别与分配清单完全相等。
- 缺失、额外或重复结果、非零进程退出、原生断言失败、整套超时均为失败；不重试。
- 超时包含构建/发现阶段，沿用原 15 分钟总期限；原生进程及其同组 fixture 子进程在结束/超时时清理。
- 日志、逐例 xunit、plan.json（全部发现项及批次）和 timing.json（用例/批次进程/墙钟）全部保留。
- 仅支持原生 XCTest；未来增加 Swift Testing 时未知发现格式会明确失败，不能静默漏跑。
- 原 `swift test --parallel --num-workers ... --xunit-output ...` 入口完整保留；
  `BCR_TEST_EXECUTION=case python3 configs/macos_workflow.py test` 可显式运行它。

原有 `test_test_summary.py` 仅在 fixture 环境明确选取 case 入口，继续验证原有逐例命令、flags、
失败/漏模块/缺报告和超时行为；全部断言保留。新增 10 个 runner 回归测试和 1 个计时源测试。
BuildWorkflow 总数从 113 增至 124，全部通过。真实子进程 fixture 覆盖：完整清单、native failure
但进程 exit 0、漏 start/finish、重复/额外结果、非零退出、保留 skip、超时清理 fixture 后代。

| 最终命令 | 用例 | 原生用例合计 s | 批次进程合计 s | workflow 墙钟 s | 失败 |
|---|---:|---:|---:|---:|---:|
| 默认 8 worker 第 1 遍 | 695 | 23.036 | 25.740 | 9.8 | 0 |
| 默认 8 worker 第 2 遍 | 695 | 22.652 | 25.229 | 8.6 | 0 |
| 默认 8 worker 第 3 遍 | 695 | 22.543 | 25.152 | 8.4 | 0 |
| BCR_TEST_WORKERS=2 | 695 | 20.347 | 21.049 | 14.8 | 0 |
| BCR_TEST_WORKERS=1 | 695 | 20.569 | 20.992 | 24.7 | 0 |

默认墙钟以三遍中位数 8.6 s 对比 P0 的 23.6 s，下降 63.6%；比 P0–P4 后的 15.6 s 再下降 44.9%。
1 worker 下连全部批次进程时间/总墙钟也小于 30 s。
批量模式的 xunit 明确标注 `timing_source=xctest-body`，工具如实显示此计时源；没有把它标成
SwiftPM per-case process 时间。旧逐例模式/原始直接 SwiftPM 命令仍有原来的启动成本，
不能声称这个未改动的直接命令本身也已达到 ≤30 s。

真实硬件 opt-in 仍为既有的一个 skip；新 xunit 正确保留它，没有新增 Swift skip 或隐藏硬件状态。
原有 3 个超 1 s 实时 IO/soak 例外仍保留。

## P5 次要仓库测量与处理

### SurfacePlugins：明确的测试替身关闭热点已修复

`python3 -B -m cProfile -o build/timings/python-before.prof -m unittest discover -s clients/python/tests`
测得 94 例 12.983 s。其中 22 次 `socketserver.shutdown` 累计 11.553 s，等待原 0.5 s poll。
这是测试专用 `surface_control_testing` 的 HTTP fixture，不是 runtime SDK，也不代表实体硬件。

`b7d9d41` 保留 `serve_forever(poll_interval=0.5)` 默认值和原 service_actions cadence，
通过本地 socketpair 唤醒 selector，再等待真实 server-finished Event；没有降低轮询间隔或等待常量。
HTTP handler、工具/权限/状态断言、SDK API 及消息保持。新增三例：

- `test_default_service_poll_interval_remains_half_a_second`：默认仍为 0.5 s。
- `test_shutdown_wakes_an_already_waiting_selector_without_polling_time`：刻意把 poll 扩大到 60 s，
  观察进入 select 后发出 close，验证由 readiness 退出；2 s 只是防挂死 deadline。
  失败时的 socket 清理不会改变已记录的失败结果。
- `test_close_joins_the_server_and_a_fresh_host_can_restart`：两轮 start/close 验证 join、重启和幂等关闭。

97 例连续三遍 0 失败：1.254 / 1.255 / 1.253 s；Pipe 10 例 0 失败，边界/diff 检查通过。
host 依赖锁未再升级；本轮 test-only Python 优化独立提交到 SurfacePlugins main。

### XTouch：已测量，不改

测量 revision `6b87473`，工作区保持干净，没有提交。

- `swift test --jobs 2`：第一次含重新编译 55.50 s（Build 44.91 s），缓存后命令墙钟 10.07 s（Build 0.62 s）。
  四个包各 4/173/127/23 例通过；实际测试包耗时约 0.043/4.656/1.942/0.017 s。
- `python3 -B -m cProfile -o build/timings/python-integration-before.prof -m unittest discover -s Tests/SimulatorIntegration`：
  48 例 27.064 s，0 失败，既有 attended hardware 1 项 skip；运行的 hardware-service 用本地 fake 或 device-access-disabled。
- 最慢项是 9.111 s 的三轮 slow-drip lease expiry 和 3.017 s 的总读取 deadline/recovery：
  它们明确断言实际 reader 跨过 hold deadline 并被自己的约 3 s 总预算切断。没有通过缩小期限或合并三轮来省时。
- 其他固定等待分别服务于实际进程时钟过期、write-budget window 与 reconnect backoff；
  没有发现类似 SurfacePlugins 那种无业务意义的统一关闭轮询热点。
- 本阶段不为次要仓库扩展跨进程测试时钟协议或改测试覆盖性质；真实 MIDI/attended 测试未运行。

## 审计更正与续作提交

上一轮 `bd61126` 新增的 `ImmutableDescriptorTests` 用 `ParameterOutputPlugin(limits: [])` 构造 fixture，
但空 limits 本来就非法，导致测试在进入描述符断言前抛错。上一轮报告把该套件写成 150 例全部通过不准确：
原日志实际是 149 例通过、1 例 fixture setup 失败。本轮完整复核发现并明确记录，没有以重跑掩盖它。

`617d08b` 把 fixture 改为一个合法 axis（0...1，maximumChange/maximumVelocity 均 1），
代码注释说明为何需要合法 gate；原全部断言、两实例和 start/stop 操作不变。
随后全量 Swift 命令 exit 0，逐例核实 150 个 completed 结果均为 passed。
BCR 的 695 例始终通过；依赖包的测试目标不会被 host 的 `swift test` 自动运行，因此单独验证不能省略。

新增本地提交：

- BCR `c691bf3` — `perf(test): batch native XCTest processes with exact case accounting`
- SurfacePlugins `617d08b` — `test: use valid output limits in descriptor lifecycle fixture`
- SurfacePlugins `b7d9d41` — `perf(test): wake loopback fixtures on shutdown without shortening timers`
- XTouch：无提交。

续作最终检查：BCR 124 个 workflow Python 用例、6 个客户端 Python 用例、20 个模块边界、
格式/命令校验/diff、MCP 双协议离屏验收和 Provider 打包/transport 检查均通过。
transport 仍是原有 17 项通过、2 个历史 SDK archive 缺失项 skip；实机 opt-in 未运行。
旧逐例入口显式运行也得到 695 例、0 失败（16.8 s，8 worker），证明该对照入口仍完整可用。

本轮没有改 Swift 生产计时、Swift 业务测试断言或测试循环常量；没有删测试、放宽断言或新增重试/预期失败/Swift skip。
用户确认前轮 push 由其本人执行；续作仅本地提交，没有 push/tag/release、branch/worktree、stash/reset。
