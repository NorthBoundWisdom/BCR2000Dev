# 测试耗时优化记录

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
P3 缓存后，进程内分别由 4.175/2.074 s 变为 0.404/0.077 s（后者以最终表为准）。
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
