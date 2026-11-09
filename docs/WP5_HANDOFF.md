# WP5 交接：功能系统扩展

已在本机 main 实现并验证，不推送；继续 WP6–WP7。

## 改动与设计

- 新增按键 stepParameter（正负、停止/越界回另一端）、setParameter、cycleParameter。
  LED 表达动作可用性/预设匹配/列表成员关系，松开恢复软件状态。引擎与 Mock 闭环覆盖每一种功能。
- 可选参数 step 按零点网格吸附，端点始终可达，等距取低；软件和输入一致。
  来源编码器被吸附时校正自身，否则保留原来的“只镜像其他控件”规则。
- 纯值批量计划保留旧/新分配与未分配数量；UI 预览后确认，拒绝过期计划，不重置参数/Agent/映射。
- 检查器新增功能编辑、步长开关和批量分配；MCP 的通用 Schema 同步扩展。
- 配置版本 v3，旧 v1/v2 读取时可见迁移；旧格式 step 缺省为 nil。
- Mock 已知不回显，Session 在 Mock 源禁用回环过滤；实体源保留 180 ms，避免把刚点亮的状态按钮误当回环。
  硬件行为假设没有增加，仍待 R1；Mock CC 1–108 规则未变。

## 检查与操作

- Swift：116 Core + 36 Console = 152 条通过；本包新增 12 条，无新增编译警告。
- BuildWorkflowTests 19 条、命令校验、compileall、workflow help、diff 检查通过。
- App build、原生 startup smoke 与现代/旧版 MCP 冒烟通过。
- 原生最小窗口下，MCP 配置步长及三种功能，实际操作 U1/U2/U3，MCP 读回每一步结果。
  E1 批量预览、确认后按顺序绑定前 8 个参数，J2 的当前值 44.5 保持。
- 回归执行配置导入导出/草稿原生流程。
- 曾发现 SwiftUI 双 State 的首轮预览为空，已改为携带明确计划的 item sheet，最终原生流程通过。

## 新增测试

- FunctionSystemTests.testStepButtonStopsAtLimitAndLEDReportsAvailabilityWhileHeld
- FunctionSystemTests.testPositiveNegativeWrappingAndDebounce
- FunctionSystemTests.testSetPresetLEDTracksSoftwareAndRelease
- FunctionSystemTests.testCycleOrderWrapAndUnlistedValue
- FunctionSystemTests.testSnappedInputCorrectsItsOwnMockRingAndOtherBindings
- FunctionSystemTests.testStepQuantizationEndpointsTieAndCanonicalSevenBitRoundTrip
- FunctionSystemTests.testEveryTriggerTypeRejectsEncodersAndInvalidFunctionValues
- FunctionSystemTests.testBulkPreviewPreservesValuesMappingAndAgentStateAndRejectsStalePlan
- FunctionSystemTests.testOldConfigurationMigrationAndNewTargetsRoundTrip
- MCPTests.testStepAndNewAssignmentTargetsAreAvailableThroughGenericSchemas
- FunctionEditorTests.testCycleTextValidationKeepsExistingAssignmentOnBadInput
- FunctionEditorTests.testBulkModelReportsStalePreviewAndCurrentValuesSurviveSuccess

## 审查重点

吸附与 7-bit 往返（固定种子 100 个范围×128 个 MIDI 值）、边界循环定义、
按钮 LED/释放/去抖、配置变化时预览失效、MCP Schema 与新 Codable 分支。
页面/层/宏与相对模式不在本包，分别留给后续与 WP7；实体行为待 R1。
