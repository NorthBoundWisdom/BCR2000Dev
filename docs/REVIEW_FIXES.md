# WP3–WP7 审查修正

本轮按七项审查意见在 main 追加修复，保留本地提交，不推送。

## 行为

1. MCP 不允许更新不可写参数定义，不允许改变已有参数的 agentWritable。
   arm.enabled 和 App 输出设置选定的使能参数始终禁止 MCP 创建/修改定义或写值，
   即使本地 agentWritable=true 也不能绕过。检查发生在额度消耗和 Session 副作用之前。
2. 启动 App 只恢复输出设置，不自动连接/恢复输出。启动、重连、心跳/实际状态故障后，
   安全门必须观察到使能关闭，再开启才允许运动；默认值为 1 或一直保持开启都会显示等待重新使能。
3. 每个运行周期发送全部安全门输出（包括未变化的关节），关闭状态持续重发空停机帧。
   仿真端同时检查心跳和控制帧的新鲜度，任一超过 350 ms 就停止。
   仅收到心跳或旧序列不能续期旧运动指令；手动退出的最后停机包仍是尽力发送，接收端独立超时是必需保护。
4. 相对输入和 NRPN 软件微调保存吸附前余量；反向抵消，边界夹紧防积压。
   参数外部修改、定义/功能/映射变化会清理相关余量。
5. reset_group 复位可写参数，返回 results 和 skipped（含 id/reason），受保护值保持。
   全部受保护时成功返回空 results；参数写权限关闭仍拒绝。
6. 机械臂预览移除全部角度 Int 转换，大数用科学记数法；绘图角度先归一化再算弧度，
   避免乘法/角度累加溢出，夹爪几何限制在绘图范围，原始读数保留。
7. 删除 PersistenceValidationTests.swift 尾部多余空行。
   检查工作区之外，还检查修复提交本身及 origin/main 到交付 HEAD 的净差异。
   原 WP4 历史提交保留，不重写历史。

## 回归与验收

- Swift 152 Core + 42 Console = 194 条通过，无新增编译警告。
- Python BuildWorkflowTests 19 + OutputSimulationTests 8 = 27 条通过。
- App build、startup smoke、命令校验、compileall、workflow help、diff 空白检查通过。
- 运行中隔离 App 的两版通用 MCP 冒烟通过；HTTP 工具拒绝可写标记/范围/默认值三种使能攻击，
  分组复位 J1 成功并明确跳过 arm.enabled。
- 原生 1200×760 下，机械臂预览实际渲染 J1–J6、夹爪、速度为 1e300，未崩溃，MCP 继续响应；截图已检查。
- 原生相对 1/2、步长 0.5/0.25 和 NRPN 8193 读数回归通过。
- 原生 OSC 关闭使能、实际 LED、断线/重启验收通过，本轮告警 255 ms。
  接收端重启且使能仍开时保持停止，操作员关→开后才恢复。
- 日志在忽略的 build/review-fixes-*.log。没有使用用户凭据或实体 MIDI。

新增重点测试：

- MCPTests.testConfigurationPermissionCannotEscalateProtectedDefinitionsOrEnableValues
- MCPTests.testResetGroupResetsWritableParametersAndReportsProtectedSkips
- MotionSafetyTests.testAlreadyEnabledStartupAndReconnectRequireObservedOffThenOn
- MotionSafetyTests.testEveryReadyFrameContainsAllLimitedOutputsIncludingUnchangedJoints
- EncoderPrecisionTests.testSlowRelativeTicksAccumulateAcrossSnappingAndExternalWritesClearRemainders
- EncoderPrecisionTests.testNRPNSoftwareFineAdjustAccumulatesAndAssignmentChangeClearsRemainder
- OutputControllerTests.testSavedEnabledOutputDoesNotAutoRestoreAndStartupHighRequiresNewEdge
- ArmPreviewTests.testExtremeFiniteAnglesFormatWithoutIntegerNarrowingAndHaveFiniteGeometry
- ArmSimulationTests.test_command_watchdog_stops_even_while_heartbeats_continue
- ArmSimulationTests.test_full_snapshot_after_lost_packet_repairs_all_targets

交付时另执行 git show --check HEAD、git diff --check origin/main HEAD 与 git status。
真实 BCR2000/机械臂仍待 R1；本轮没有作真机验收声明。
