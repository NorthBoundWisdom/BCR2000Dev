# 共享插件与 BCR 兼容边界

更新：2026-11-12。BCR 已接入共享 Agent；跨宿主 M1 尚待 XTouch 接入同一版本。机器人、底盘、输出与安全门仍在本仓库，属于后续 M2；远程合同共用属于 M3。

## 依赖与本地构建

`Package.swift` 固定 `https://github.com/NorthBoundWisdom/SurfacePlugins.git` 的精确 `0.1.0`。
远端仓库已存在，当前远端 main 仍为初始提交 `09191a9`；共享业务实现和 `0.1.0` 标签尚未推送发布。
当前使用已有的并列 `SurfacePlugins` 工作副本：

```bash
export SURFACE_PLUGINS_PATH=../SurfacePlugins
swift test --build-path build/swiftpm
python3 configs/check_domain_boundaries.py
python3 configs/macos_workflow.py build
```

也可把 `SURFACE_PLUGINS_PATH` 放在被忽略的 `build.local.json` 的 `environment` 中，
`macos_workflow.py` 的 build/test 会继承它；直接 Swift/边界脚本需要 shell 环境变量。
继承的环境变量优先于本机配置。没有提交机器绝对路径或固定相对路径依赖，宿主不依赖另一个控制台仓库。
共享包是独立的业务插件库，不属于禁止的额外宿主 clone/分支/worktree。

当前只作本地提交，不推送或创建远端/标签。用户决定推送共享实现并发布 `0.1.0` 后，再安排宿主推送时机；
未发布前不能声称远端解析或干净 CI 已通过，也不提交虚构的 `Package.resolved`。

## 归属与运行

| 模块 | 职责 |
| --- | --- |
| `SurfacePluginContracts` | Foundation-only 的参数/动作/指示合同、命名空间、来源、注入时间及结构化错误 |
| `AgentPlugin` | 唯一的七态转换规则与 Mock 时间线，`Sendable` 值类型、同步确定输入 |
| `BCRPluginHost` | 事务注册与显式选择插件；MainActor 持有实例、单调时钟驱动、逐事件发布旧宿主快照 |
| `BCRConfigurationAdapter` | 旧 target 到中性动作/指示 ID 的翻译、设备七位值映射、旧反馈 API 兼容扩展 |
| `BCRSurfaceDomain` | 控制台引擎、MIDI/学习/反馈管线；按 `IndicatorID` 存反馈，不解释 Agent 命名空间/状态 |
| `BCRAgentDomain` | 共享 `AgentRunState` 类型别名、宿主本地化及旧 Date/name/Codable/error 投影包装；`allows` 调用共享规则 |
| App / Codex adapter | 后端进程、真实审批、凭据、UI 与协议生命周期 |

注册先校验整个批次的 ID、合同版本和声明命名，再启动候选值，全部成功才生效。失败无半注册残留。
Mock 的阶段与进度保持原值；主线程阻塞后的时间推进按单调注入时钟追赶，依次发布全部到期阶段，
包括同一时刻的 0.58 prepare 与 0.60 waiting。时钟不由窗口刷新驱动。
设备来源仍可批准 Mock；真实 Codex 的设备来源只提示到 Agent 页查看批准，不改变真实审批。
显式中断/拒绝使用共享 typed `interrupt`，只取消指定槽位且不会把 waiting 误批准。

## 旧源码与磁盘兼容

`BCRAgentCore` 继续导出旧入口。`AgentSlot` 的名称、状态文本、`lastUpdated: Date` 和编码字段保留；
旧 Date-based 状态机签名/错误保留为兼容包装，其转换允许表直接调用共享状态机。新产品 Mock 不使用这份包装运行。
设备反馈 `feedbackValue` 兼容属性在配置适配器扩展中，映射为 idle 0、queued 40、running 127、waitingApproval 96、completed 72、interrupted 20、error 8。

父工作区 D8 明确允许保留旧 `ControlTarget.agentPrimaryAction`、`SurfaceEffect.triggerAgent`、
`onTriggerAgent` 和未注入绑定时的旧 fallback，以保留旧枚举构造与 pattern matching。
GUI 与无界面服务都注入 `AgentBindingTranslation.bindings`，生产引擎主路径只返回 `triggerAction`；
旧 `setAgentFeedback` / `agentFeedback` 是适配器扩展，实际存储始终为中性指示 ID。

新增 `SurfaceEffect.triggerAction` 后，外部无 default 穷举全部旧 case 的 switch 必须处理新 case。
因此这里不承诺所有消费者源码零修改；承诺保留旧成员构造、模式匹配和方法行为。
未添加新的持久化 target case，旧 `agentPrimaryAction` JSON、配置版本、保护标记及 Provider 1.0 Schema 保持原样。

`AgentSlotID(_:)` 是旧非 throw 构造，保留 raw 值并不再 precondition 崩溃。
新调用用 `try AgentSlotID(validating:)`；解码、配置校验及插件绑定边界拒绝越界。
插件自身的槽位数量可配置，BCR 兼容表仍为 1…8。

## 验证边界

B0 原始基线 356 个 Swift 测试，B0 锁定后 359；B1 为 369，B2 为 374，B3 为 376。
包含旧断言保持、七值反馈、同步 LED 顺序、事务失败、逐阶段/大跳重放及无窗口驱动。
B2 与 B3 的自包含 Provider 产物分别通过原样 14 组黑盒验收，原生 App 构建、双语 1200×760 startup 和两版 MCP smoke 通过。
逐任务实际测试数量及日志由工作区 `reports/B.md` 追加记录。

这些均是软件/Mock 证据。硬件没有连接；C03、C05、真实控件/断插/灯环和人工 GUI 布局未验证。
远端版本解析、Linux/CI 执行与 XTouch 的同源快照对比尚未验收。真实执行器从未连接。
