# 共享插件与 BCR 兼容边界

更新：2026-11-12。BCR 与 XTouch 已接入同一共享固定提交，Agent 参考序列与独立共享注册表相符；
机器人、底盘、输出、安全门与示例数据均使用共享核心，新 `surface_` 合同已装配。正式推送/发布与实机验收仍独立。

## 依赖与本地构建

`configs/surface_plugins.lock.json` 提交 HTTPS remote 与完整40位 commit revision。
`Package.swift` 只引用固定 `build/dependencies/SurfacePlugins`，不通过 SwiftPM 解析远端或标签。
Python stdlib + Git 的 `configs/surface_plugins_dependency.py` 将锁定提交物化到该路径；不依赖 FreeCM。

远端仓库已有初始 main，业务提交未推送；当前从已有并列 Git 副本获取已提交的锁定对象：

```bash
export SURFACE_PLUGINS_SOURCE=../SurfacePlugins
python3 configs/surface_plugins_dependency.py ensure
swift test --build-path build/swiftpm
python3 configs/check_domain_boundaries.py
python3 configs/macos_workflow.py build
```

`SURFACE_PLUGINS_SOURCE` 仅是 Git 获取源，不是编译路径；不会复制工作树中的未提交改动。
旧 `SURFACE_PLUGINS_PATH` 兼容解释为获取源，两个变量不一致时报错。也可在 ignored `build.local.json`
的 `environment` 中配置 SOURCE，构建/测试/配置/Provider打包入口会加载后先ensure；直接helper CLI使用shell环境。
锁文件升级后，已有干净且manager-owned缓存须显式运行 `python3 configs/surface_plugins_dependency.py update`。
普通ensure和只读verify对错SHA、dirty（含ignored文件）、非manager目录或symlink拒绝，不reset/clean任何源码目录。

缓存命中只检查本地对象/HEAD/dirty，不再次联网。物化使用独立staging、文件锁和原子rename；
Package执行只读verify，因此直跑Swift也不能绕过缓存检查，且清单验证不获取依赖/不联网。
所有编译都从build内锁定提交进行，不直接编译并列副本。两个宿主复制同一helper与锁格式，各自独立物化；
不依赖另一个宿主源码。CI构建入口先ensure，未推送SHA的远端获取仍未验证。

当前只作本地提交，不推送或创建远端/标签。用户决定共享实现与版本发布时机；
锁定commit不依赖标签是否存在，不提交虚构的 `Package.resolved`。

## 归属与运行

| 模块 | 职责 |
| --- | --- |
| `SurfacePluginContracts` | Foundation-only 的参数/动作/指示合同、命名空间、来源、注入时间及结构化错误 |
| `AgentPlugin` | 唯一的七态转换规则与 Mock 时间线，`Sendable` 值类型、同步确定输入 |
| `SimulationContracts` / `RobotPlugin` / `ChassisPlugin` | 唯一控制权/机器人积分/Ackermann核心；旧BCR领域仅typed facade与错误文案映射 |
| `BCRPluginRuntime` | 每宿主唯一RemoteRegistry/epoch/单调clock；事务安装、typed value+event原子提交；无domain switch |
| `BCRPluginHost` | Mock Agent adapter/驱动，GUI注入共同owner；逐事件发布旧快照，不持第二份插件 |
| `BCRConfigurationAdapter` | 旧 target 到中性动作/指示 ID 的翻译、设备七位值映射、旧反馈 API 兼容扩展 |
| `BCRSurfaceDomain` | 控制台引擎、MIDI/学习/反馈管线；按 `IndicatorID` 存反馈，不解释 Agent 命名空间/状态 |
| `ParameterOutputPlugin` / `ExampleParameterSets` | 唯一安全门、OSC/JSON链路核心及示例参数数据；旧Date/默认地址/本地化/布局留宿主薄适配 |
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

机器人/底盘的旧Proof/Grant/Metadata/Source及状态DTO直接alias共享合同，JSON字段不变。
旧领域包装保留方法签名与自定义模型字段，算法全部委托共享核心。宿主每实例注入UUID命名空间，
每次grant注入新的opaque UUID token；token不进入快照。generation现在是命名空间加本地代次的opaque字符串，
消费方不得依赖旧UUID外形。共享reasonKey经完整映射恢复旧ProviderDomainError的code/message。
新建旧API包装显式start；注入已有plugin时保留其生命周期。插件生命周期stop后旧typed写也被acceptsWrites门禁拒绝，
advanceSimulation仍可完成制动且不会复活；受控motion-stop与生命周期stop保持不同语义。

输出迁移保留旧Date API和包格式；共享核心只接注入秒数，不读系统时钟。JSONValue和ParameterID直接alias同形共享基础类型，
旧单字符串ID/构造/排序/JSON helpers保持。参数失败诊断用core的parameterID还原原文，不复制校验；
JSON session UUID与OSC默认/bcr地址仍由宿主注入。示例九个参数的范围/默认值/名称/显式保护标志保持，布局不进共享数据。
更保守的有意变化：心跳间隔一旦越过期限，即使新心跳先于下一次evaluate到达，也必须真实关闭/开启使能后才恢复；
回退或非有限心跳时间会给可见clockError并保持关闭。

## 验证边界

B0 原始基线 356 个 Swift 测试，B0 锁定后 359；B1 为 369，B2 为 374，B3 为 376。
包含旧断言保持、七值反馈、同步 LED 顺序、事务失败、逐阶段/大跳重放及无窗口驱动。
B2 与 B3 的自包含 Provider 产物分别通过原样 14 组黑盒验收，原生 App 构建、双语 1200×760 startup 和两版 MCP smoke 通过。
逐任务实际测试数量及日志由工作区 `reports/B.md` 追加记录。

这些均是软件/Mock 证据。硬件没有连接；C03、C05、真实控件/断插/灯环和人工 GUI 布局未验证。
两宿主JSON锁和实际物化缓存同为 `add3c2404e4d2dbe3f9d0861bbda01c013018669`。
BCR 最终408个Swift测试、66个工作流测试、6个客户端测试；既有Provider14组黑盒以及新工具现代/2025协议HTTP验收通过。
Root独立Linux对共享最终103测试、XTouch Core/L10n 84测试及共同Gitmanager11测试验证通过，证据在工作区reports/REVIEW。
GitHub远端CI/尚未推送SHA获取与真实硬件未验，不把本地Docker结果称为远端CI。真实执行器从未连接。

统一工具、权限、游标与时间域详见 [共享远程工具](SHARED_REMOTE_TOOLS.md)。


输出精度：仅OSC使用float32。首次/重武装actual必须精确Float可表示，否则invalidActual+参数诊断，禁止epsilon放宽或改写actual；
JSON/WebSocket/rosbridge保留Double。生产OSC/WS/rosbridge在实际IO接收处采monotonic时间，经有界缓冲原样交MainActor；Controller只消费Mono通道，保持排队age。
生产ping cadence与RTT也全为Mono，不受墙钟跳变；Date仅legacy facade/审计兼容，旧Date-only夹具仍走原投影。坏clock下普通写失败，安全撤权/fault使用最后可信时间并记录诊断。
