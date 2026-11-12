# 共享远程工具与旧 Provider 兼容

更新：2026-11-12。两宿主固定共享提交 `add3c2404e4d2dbe3f9d0861bbda01c013018669`。
准确 inputSchema/outputSchema 从各宿主 `tools/list` 发现，完整typed合同随共享依赖的
`build/seed/SurfacePlugins/docs/remote-tools.md` 提供。所有新输出Schema为object，兼容当前和2025-11-25 MCP。

## 一份状态、一个事件游标

每个宿主只有一个 `BCRPluginRuntime` / `RemoteRegistry`（XTouch为其自己的同职责owner），
一个事件epoch与可信单调时钟。GUI Agent、输出控制器与Provider机器人/底盘全部注入该owner。
旧typed API只临时读取binding.plugin、修改后带time/event原子replace；不另存第二份模拟器或安全门。
注册按整批验证并启动候选值，失败无半注册残留。旧临时PluginRegistry已删除，注册断言迁到canonical owner。

| 工具组 | 工具 |
| --- | --- |
| 通用 | `surface_capabilities`、`surface_events` |
| Agent | `surface_agent_snapshot`、`surface_agent_primary`、`surface_agent_interrupt` |
| Robot | `surface_robot_snapshot/trace/initialize/acquire/enable/renew/release/stop/move/advance/reset` |
| Chassis | `surface_chassis_snapshot/trace/initialize/acquire/enable/renew/release/stop/drive/advance/reset` |
| Output | `surface_output_snapshot/enable/disable` |

只有显式装配的插件组会被发现。GUI默认选Mock Agent与有效限位的Output policy，参考机器人/底盘仍由
`--robot-sim` / `--chassis-sim` 显式启用。无界面服务仍 `includeAgent=false`，只按原配置选择机器人/底盘。
同插件多实例按 `instance_id` 路由，动作参数不代表身份或权限。

## 线上表示与权限

旧Provider1.0所有工具/错误/Schema和`{data:...}`结果包裹保持。新 `surface_` 返回共享raw对象：
`structuredContent` 与text中的JSON相同；失败为 `{code,fields}` + `isError:true`。
新trace为 `{samples:[...]}`；旧Provider trace保持原样。不要用只理解旧data包裹的SDK1.0通用返回解析器直接解析新工具。

BCR新工具权限不绕过原能力边界：

- Agent写：parameterWrite + agentControl；localOrigins允许硬件/UI批准Mock，拒绝remote批准。
- 机器人/底盘普通写：parameterWrite +相应control；reset另需simulationControl。
- 显式advance：parameterWrite + simulationControl，且必须manual clock，不能用新工具绕过旧simulation_advance模式限制。
- Output写需parameterWrite，remote enable的额外context授权默认false。disable立刻生成/发送安全停帧，不伪造实际观测。
- acquire每次由host提供新的opaque UUID，不从JSON读取entropy。新工具仍受同一写速率限额。

Codex真实审批仍走原详情/呈现/独立确认界面；共享工具只操作Mock，Codex backend选中时Mock停用。
读取snapshot/events不推进时钟、不追加日志。失败命令不提交state/journal。请求丢响应后重新取快照，禁止自动重放副作用。

## 时间、停止和输出精度

registry context统一systemUptime/注入单调秒；typed仿真dt独立于host时钟。
Provider按注册路由推进，不按domain字符串switch。时钟回退/NaN/异常间隔会真实撤权并呈现host_clock_gap，
安全fault/stop可用最后可信时刻提交诊断；普通写仍拒绝坏时间。持续回升但未追上可信水位不会推进或崩溃。

生产输出在OSC串行receive queue与WS独立reader的真实收包处直接采Mono，带时戳经过有界handoff，保留排队age。
Controller只消费一套Mono通道，ping cadence/JSONLink与OSC RTT也全Mono；墙钟仅兼容/审计，Date-only夹具保留旧域。新disable不能被UI轮询的旧enable=true覆盖，必须真实off/on才重武装。
仅OSC使用Float32；首次/重武装actual若不精确可表示则invalidActual+参数诊断，无epsilon、无改写actual。
JSON/WebSocket/rosbridge使用Double，0.1可按Double原样输出。

## 事件分页与恢复

`surface_events` 的 `latestSequence` 是全局高水位，不是每一页读完后的cursor。
无gap时，下次after必须为**本页最后实际返回event.sequence**，否则limit小于积压量会静默跳过后半页。
有gap则先重新读取快照，再将epoch与cursor重锚到该gap响应的epoch/latestSequence；快照期间新增事件仍可继续读取。
事件只作状态变化通知，不把事件名当作待重放命令。

## 可复核软件证据

BCR最终408项Swift测试保留旧断言，包含同一owner/旧新API状态、时间桥、权限、Int.max精确解析、clock故障安全撤权，
以及与XTouch相同Agent序列（start0、remote primary1、advance1.45/2/3.7、remote primary4拒绝）对独立共享注册表完全相符。
当前Provider产物14组原黑盒通过。独立HTTP探针在native App发现8个新工具，在机器人/底盘headless产物发现24个，
均通过2026-07-28和2025-11-25的raw对象Schema/授权/控制/trace与逐条分页验证。

```bash
python3 configs/macos_workflow.py build
python3 tools/mcp_integration.py --script tools/verify_shared_plugins.py
```

这是隔离软件/Mock/参考模拟证据；真实硬件、C03/C05、真实执行器和人工GUI布局未验证。
Root另用独立官方Linux容器验证共享103、XTouch Core/L10n84、manager11；远端CI与尚未推送SHA的HTTPS获取未执行。

## 发布前事件策略修正

共享journal默认1024项，不是把容量单独放大来容忍周期性记账。`replace(at:event:nil)`显式静默提交仍更新并校验独立写时钟，
不编码事件、不广播无用observer。空闲sim=0事件，运动actual默认每0.25s最多4Hz，phase/control/fault/首末即时；
typed旧Provider也调用共享simulationEvent策略，不另写过滤规则，命令同步观察基线但只记录一次命令。
输出HB/actual记账为静默，evaluate只在status/reasonKey+parameterID/limited变化时记事件，连续numeric/frames/UI数值仍更新。
两个持续运动设备约8次/秒加未限频critical/command，1024项约容纳128秒的纯运动更新；命令风暴仍可能gap，按既定cursor恢复。
旧Provider1.0 revision/time/trace和50Hz legacy devices SSE语义独立保留，不随shared journal降频。

四个默认instanceID统一由binding constants提供：agent.mock、robot.reference、chassis.reference、output.parameters。
客户端仍应先发现能力。旧Provider device_id不变。新整数解析使用exact helper；旧v1调用显式roundedIntValue保持其历史舍入语义。

## 生产接收时钟与缓冲

WS/rosbridge reader连续在MainActor之外接收，OSC在已有NW queue接收；每包先采systemUptime再解码/交接，
bufferingOldest默认64（WS独立于原outgoing queueLimit）。满后明确drop/failure并关连接，旧buffer可drain但其采收时间不重写。
生产Controller忽略同时发出的Date兼容回调，不存在重复HB提交或wallAnchor污染。真实loopback测试以peer PING marker确保请求已发、
80ms后reply期间阻塞MainActor650ms，恢复后HB仍失鲜/actual被丢弃；另测墙钟±小时跳变、双回调与burst overflow。
