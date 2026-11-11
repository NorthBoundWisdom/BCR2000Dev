# WP7 交接：相对编码与 14-bit NRPN

> 历史交接 / 任务记录，保留当时的实现状态与验收结果；当前工作以
> [TODO](../../TODO.md) 和 [ROADMAP](../../ROADMAP.md) 为准。文中代码路径均相对仓库根目录。

已在 main 工作区实现并验证，提交仅保留本地，不推送。WP3–WP7 已按顺序完成。

## 改动与取舍

- ControlAssignment 增加 absolute（默认）、relative1、relative2 与正数 encoderStep。
  两种相对编码依据厂商手册；相对增量为步长 × 消息有符号幅度，保留设备加速度，
  不额外假设硬件时间曲线。相对输入后所有关联 LED 都写回绝对位置。
- MIDIControlID.number 扩至 UInt16，按 kind 校验 7/14-bit 范围；NRPN 语义消息保留全数值。
  单个 UMP 编码不能容纳 NRPN 时明确抛错，encodeWords 与 MIDI1 字节输出完整四 CC。
- 按通道隔离的 NRPNAssembler 支持跨回调、不完整/交错序列、选择器替换、RPN 取消、
  500 ms 间隔与时钟倒退重置；只在完整 CC6/38 后应用值。
- 学习明确选择 CC/Note 或 NRPN，普通 CC99 不被猜测。NRPN 通道上的保留 CC 身份冲突拒绝；
  学习完成才保存和自动前进。所有设备回写仍由 Engine 效果进入 Session。
- Mock 默认 CC1–108 不变。检查器提供临时单编码器 NRPN（通道 16）实验，发出真实四 CC 批次；
  不写实体映射，不自动改变实体预设。相对模式、分辨率、步长和原始 14-bit 读数可见。
- 功能配置和硬件映射升级 v4，旧模式默认 absolute/1；硬件 v3 身份保留。
  迁移提示可见，后续保存前保留精确原始字节备份。

## 验证

- Swift 146 Core + 40 Console = 186 条全部通过，无新增编译警告。
  本包新增 EncoderPrecisionTests 14 条、ConfigurationPersistenceTests 迁移备份 1 条。
- 测试覆盖两种编码正负/中性/幅度/边界、步长/反向/切换、所有 16384 个绝对 NRPN 位置、
  Mock 双向闭环、相对 NRPN、实际反馈不改目标、14-bit 回环比较、非法输入、
  跨回调学习保存、保留 CC 冲突、迁移和 MCP schema/权限路径。
- Python BuildWorkflowTests 19 条、OutputSimulationTests 6 条通过。
- 命令校验、compileall、workflow help、git diff --check、App build/startup smoke 通过。
- 最小 1200×760 原生窗口：相对 1/2，步长 0.5/0.25，正负操作；临时切换 NRPN，
  单步读回约 0.033°、原始值 8193；截图已检查布局。
- 原生配置导入导出/草稿冲突、步进/指定/循环/批量分配、OSC 禁用/实际 LED/断线/重启全回归通过。
  本轮仿真退出后 UI 271 ms 告警；恢复从新鲜实际状态开始。
- 每个原生流程都先运行现代 2026-07-28 和标准旧版 2025-11-25 的通用 MCP 冒烟，通过。
  日志位于忽略的 build/wp7-*.log；未使用用户 Keychain 或实体 MIDI。

## 审查重点与边界

- 相对回显不可直接按绝对同值过滤；真实回显、消息幅度/方向、NRPN 选择器保留方式、
  LED 绝对反馈和非当前组行为均待 R1 实机验证。本包只声称 Mock 验收通过。
- 14-bit 数据路径不可退化成七位；NRPN 组包不能跨参数误拼，也不能吞掉普通 CC。
- 参数 step 是全来源吸附，encoderStep 是相对输入灵敏度；设置较粗的参数 step 会覆盖细调结果。
- 外部仿真不等同于真实机械臂，真实执行端的独立停机保护仍未验收。
- 发现但未处理：现有 ArmPreviewView 对极大自定义角度使用 Int 转换，可能超出显示范围。
  该问题已在后续审查修正中解决，见 [REVIEW_FIXES.md](REVIEW_FIXES.md)。

完整编码规则、手册来源与迁移见 [CONTROL_MAP.md](../CONTROL_MAP.md)，
通用 MCP 接口见 [MCP.md](../MCP.md)，OSC 仿真见 [OSC.md](../OSC.md)。
