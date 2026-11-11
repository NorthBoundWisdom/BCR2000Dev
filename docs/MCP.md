# 通用 MCP 控制接口

BCR Console 提供客户端无关的 Model Context Protocol 服务；无需任何厂商 SDK 或私有扩展。
传输为 Streamable HTTP，端点是 http://127.0.0.1:8787/mcp（端口可配置）。
可由支持此传输的 MCP 客户端接入，本轮以 Python 标准库客户端验收；只有 stdio 的客户端需要自己的传输桥接。

## 协议版本

主协议按 [2026-07-28 规范](https://modelcontextprotocol.io/specification/2026-07-28) 实现：
每个请求独立携带 params._meta 内的协议版本和客户端能力，支持 server/discover。
HTTP 必需 MCP-Protocol-Version、Mcp-Method；tools/call 另需 Mcp-Name，均校验与消息体匹配。
名称的 Base64 哨兵编码按规范解码。成功结果包含 resultType=complete 和服务器元数据。
不创建现代版会话，不要求 initialize；传输细节见
[Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)。

同时兼容 [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)：
initialize → notifications/initialized → 工具调用；初始化返回 Mcp-Session-Id，
后续请求必须携带该头与对应 MCP-Protocol-Version。旧会话最多 32 个，闲置 30 分钟过期，可 DELETE。
旧握手不是任何特定客户端的专用协议。UI 的会话计数只代表此兼容模式；现代版无协议层会话。

所有请求均为单条 JSON-RPC 2.0 消息。响应为 application/json；通知接受后返回无消息体的 202。
未实现的方法返回 -32601；现代版同时返回 HTTP 404。GET 的受鉴权参数事件 SSE 见下文扩展；未协商事件流时返回 405。
没有广告通用资源订阅或 MRTR 能力。现代版元数据错误返回 400/-32020，不支持版本返回 400/-32022。

## 安全与设置

- 默认关闭；在顶栏 MCP 设置中显式开启。启用状态、固定端口和权限保存在本机 MCP 设置文件。
- 只监听 127.0.0.1；端口占用立即报错，不换随机端口。端口 0 仅供隔离回环测试。
- Keychain 查询在后台执行，等待授权不阻塞视窗；等待期间可停止，迟到的凭据不会重新开启服务。
- 首次启用生成 32 字节安全随机 token，以 64 位十六进制形式存入 macOS Keychain。
  Token 不进入配置 JSON、日志、审计记录或仓库；复制动作只写入剪贴板。
- 每个请求必须有 Authorization: Bearer <token>；缺少/错误返回 401。
- Host 必须指向当前本机端口。Origin 可缺省（命令行客户端），存在时只能是同端口的
  http://127.0.0.1 或 http://localhost；非本机、不同端口和 null Origin 返回 403。
- 参数写入默认开启；配置写入默认关闭。关闭参数写入时只读，不能保留配置写入。
- 参数还必须允许 agentWritable；“机械臂示例”预置的 arm.enabled 默认不允许 Agent 写入。
  本文示例中的 arm.* 参数来自该预置；首次启动的默认配置使用 general.1…general.8。
- 每秒默认最多写 60 个参数，批量按成员数量计数。超限整批拒绝，返回可读的工具错误。
- HTTP/1.1 请求需要明确 Content-Length；请求体最多 1 MiB、头部最多 16 KiB、并发连接最多 32；
  接收期限 5 秒。分块传输和管线请求明确拒绝，不对残缺数据进行猜测。
- 所有写入经过 SurfaceSession；软件参数、UI 和 LED 同步。MIDI 监视器来源为 AGENT。
- 一键停止取消监听、关闭连接并清空兼容会话。工具调用记录仅保留最近 100 条。

## 工具与 Schema

tools/list 返回权威 JSON Schema（inputSchema、outputSchema 与只读提示），不按客户端身份改变。
工具结果带 content、structuredContent、isError；结构化输出固定为对象 data，data 的类型如下。
业务错误是 isError=true，data.error 为可读原因；协议/传输错误使用 JSON-RPC/HTTP 状态。
配置保存失败会明确返回“内存已更新、持久化失败”，不会把暂存状态伪装成已保存。

| 工具 | arguments | data 输出 |
|---|---|---|
| get_status | 空对象 | source、connected、hardwareConnection、droppedFeedbackCount、permissions、configurationPersistenceError |
| list_parameters | 空对象 | 参数信息数组 |
| get_parameter | id: string | 一个参数信息 |
| set_parameter | id: string, value: number | id、value（实际值）、clamped |
| set_parameters | values: [{id, value}]，1–256 条且 id 不重复 | 写入结果数组；先全部校验，任一失败则不改任何参数 |
| nudge_parameter | id: string, delta: number | 与 set_parameter 相同 |
| reset_group | group: string | 对组内可写参数复位；返回 {results: 写入结果数组, skipped: [{id, reason}]}，受保护参数保持原值 |
| list_controls | 空对象 | 108 个 control、label、assignment、binding、value |
| assign_control | assignment: 完整功能分配对象 | 保存后的分配，需要配置写入 |
| create_parameter | definition: 参数定义对象 | 创建后的参数信息，需要配置写入 |
| update_parameter | definition: 参数定义对象 | 更新后的参数信息，需要配置写入 |
| set_device_source | source: mock / hardware | 需要 parameterWrite 与 deviceControl；外部输出停止、无学习活动；实体源必须有健康双向 MIDI 路由 |
| begin_control_learn | control: 控件对象 | 仅实体源、健康路由、外部输出停止时等待实际输入；拒绝覆盖已有学习映射 |
| stop_control_learn | 空对象 | 停止学习，需要配置写入 |
| restrict_configuration_write | 空对象 | 关闭配置写入权限；GUI 持久化，独立服务按进程启动策略；不能通过 MCP 重新开启 |

所有 inputSchema 都是 object、additionalProperties=false，required 字段见上表。
参数定义包含 id/name/group/unit/minimum/maximum/defaultValue/kind/agentWritable/step；
id 和 name 必需，其余默认与 App 创建参数一致。update_parameter 接收完整定义，不是补丁。
step 可缺省或为 null（不吸附），启用时为正数；kind 是 continuous 或 toggle；数值必须有限，minimum < maximum，默认值在范围内。
参数信息另包含 value、writable、只读 actualValue/outputValue 和绑定的 controls；更新定义时不回传这些运行字段。

控件使用 section、row、index，范围由 section 决定。分配包含 control、target、
buttonBehavior（toggle/momentary）、inverted，以及可选 encoderMode（absolute/relative1/relative2）和正数 encoderStep。target 与版本化 SurfaceConfiguration 共用 JSON 编码。
例如给 E1-1 绑定 J1：

    {"assignment":{"control":{"section":"encoder","row":1,"index":1},
      "target":{"parameter":{"_0":"arm.j1"}},"buttonBehavior":"toggle","inverted":false}}

准确的枚举分支与字段范围也由 tools/list 的嵌套 oneOf schema 提供。

`get_status.learningControl` 是当前等待学习的控件或 null。学习工具不制造输入；实际消息仍来自
CoreMIDI，经原 SurfaceSession 路径保存。自动跳到下一未学习控件后应显式 stop，不能把设备快照
回读与等待实体按键学习同时运行。来源切换和学习均不会开启 OSC 输出，也不会写设备预设。

程序启动可显式传入 `--mcp-token-stdin`：只接受匿名 FIFO 管道中的 64 字节小写十六进制凭据，
保存在进程内存中，不进入 argv、配置或日志。该方式不能与 startup-smoke / integration-test 混用；
正常启动仍从 Keychain 读取。用于已获授权的本机父进程从 Keychain 取得凭据后启动重建的 App，
不接受终端或普通文件输入，不更改 Keychain 访问策略。凭据权限与 HTTP 鉴权保持相同。

## 通用客户端验收

在 MCP 设置中启用服务并复制 token；只把凭据放入本机环境变量，不要将它写到命令文件或仓库。

    export BCR_MCP_TOKEN='<从设置复制的 token>'
    python3 tools/mcp_smoke.py
    python3 tools/mcp_smoke.py --legacy

脚本仅使用 Python 标准库，执行发现/初始化、tools/list、写入与读回、保护参数拒绝、批量原子性、
错误 token 与非法 Origin 检查。它恢复原参数值并清理旧会话，不打印凭据。
MCP 设置里的“复制连接命令”给出通用 curl server/discover 请求，不需要特定 Agent CLI。

当前配置 v7、硬件映射 v4。v7 用 externallyProtected 显式声明外部写保护，优先于 agentWritable；
旧配置的示例保护由兼容适配器迁移，通用会话没有保留参数名。
App 显示迁移提示，并保持原文件直到用户后续修改配置。

## 隔离原生验收

重复构建时可运行 python3 tools/mcp_integration.py。它用 Debug App 的显式 --integration-test 模式，
生成独立数据目录与内存测试凭据，默认在 18787 端口执行两版 MCP 冒烟，结束后关闭测试 App。
它不读取用户 Keychain，也不接触用户配置或实体 MIDI；Release 构建拒绝该测试模式。
可用 --script 指定额外本机验收脚本；脚本通过本地环境取得测试端点、测试凭据及测试 App PID。
测试环境缺失或格式错误时明确失败，不回退到用户数据。

新增 target JSON 分支可通过同一个 assign_control 工具使用，无客户端专属工具：
stepParameter: {id, step, wraps}；setParameter: {id, value}；cycleParameter: {id, values}。
例如 target={"stepParameter":{"id":"arm.j1","step":0.5,"wraps":false}}。
这些功能同样受配置写入权限和整体校验限制；普通参数写入返回的 clamped 也标明吸附造成的调整。

### 审查修正：写入权限边界

配置写入权限不授予修改权限策略的能力。update_parameter 不允许改变已有参数的 agentWritable，
也不允许修改当前不可写参数的任何定义。externallyProtected 参数和输出设置选定的使能参数始终禁止 MCP
修改定义或写值，即使其 agentWritable 为 true；已有保护字段也不能由 MCP 去除。
get_parameter 的 writable 反映此约束。reset_group 跳过这些参数并明确返回 skipped；
其余可写参数仍在全部验证、限速通过后统一复位。参数写权限关闭时复位仍被拒绝。

## stdio 桥接

客户端启动 `python3 tools/mcp_stdio.py --url http://127.0.0.1:8787/mcp`，将 Token 放在子进程环境的
`BCR_MCP_TOKEN`。桥接器仅允许本机 IPv4 HTTP，禁止代理与重定向；不打印凭据。
stdin/stdout 使用一行一个 JSON-RPC 对象，通知不返回响应，EOF 时删除 HTTP 会话。
运行 `python3 tools/mcp_integration.py --script tools/verify_stdio_bridge.py` 可验收握手、工具探索与状态调用。

## 参数事件推送

经相同 Bearer、Host、Origin 校验后，客户端可 `GET /mcp`，指定 `Accept: text/event-stream` 和
`MCP-Protocol-Version`。2025-11-25 客户端还需已 initialized 的 Mcp-Session-Id。
服务器通过 experimental 能力 `bcr/parameterChanges` 公布扩展；不引入第三方 SDK。
通知是 `notifications/bcr/parametersChanged`，params 含 revision（十进制字符串）、values、removed、reset。
新流先发送 reset=true 的完整参数快照，后续只发送变更；重新连接重新取快照，不重放运动命令。
这是 BCR 扩展通知，不冒充通用 MCP resources 订阅。客户端应检查能力并识别此通知。
事件按 16 ms 合并最新值；每流增量待发送上限 64 KiB，完整快照独立上限 8 MiB，最多 16 条流；慢客户端断线，10 秒心跳维持活跃连接。停止服务/删除旧版会话会关闭流。
运行 `python3 tools/mcp_integration.py --script tools/verify_parameter_events.py` 验收现代/旧版鉴权、快照和变更回读。

## Agent 与设备控制权限

`get_agents` 只读返回后端及槽位状态。`start_agent(slot)`、`interrupt_agent(slot)`、`stop_all_agents` 需要
parameterWrite 和新增的 agentControl 权限；`set_device_source(source)` 还需要 deviceControl 权限。
两项新增权限默认关闭，旧设置迁移时也保持关闭；可在 MCP 设置页明确开启，所有写入共用速率限制与审计。
启动使用本机 Agent 设置中已配置的任务，返回 accepted 表示请求已接收，执行结果从 get_agents 查询。
MCP 不提供审批通过接口。Codex 启动可能使用本机登录账号；仅向受信任的客户端授予此权限。
隔离测试禁止通过 MCP 切换至实体设备。所有设备切换仍经过 App 的停机/映射路径。

start_agent 仅接受 slot，不接受 prompt，使用本机 Agent 设置的当前任务内容；缺失、非整数或超出 1–8 的槽位明确拒绝。
list_controls 与 assign_control 作用于当前会话页面；get_status 的 activePage 标明该页 ID（基础页为 `__base__`）。
页面选择只在本次会话中有效，配置文件与导出不携带当前页面。

大于增量上限的有效变更会转换为当前完整快照，避免永久无法订阅；初始快照不占增量额度。
断线、服务停止会取消待刷新事件；服务器释放时移除参数观察者并关闭连接。

## Provider 1.0 与独立无界面宿主

公开设备合同、完整输入/输出 Schema、启动与安装步骤见 [Provider API](PROVIDER_API.md) 和
[公开接线入口](PROVIDER_QUICKSTART.md)。新能力通过模块注册，机器人/底盘未启用时不注册其命令，明确返回 unsupported。
独立服务不注册 Agent 工具；GUI 与服务使用同一应用服务，互不读取消费方业务对象。

`provider_id` 为应用实例启动唯一身份，GUI 内只重启 HTTP 不改变身份，进程重启必变；资源 generation
另行管理。客户端通过 `BCR-Provider-Id` pin，服务在 RPC/SSE 处理前拒绝错误实例（409）并回显身份。
无 pin 只保留旧客户端兼容。新接线应固定预期实例，不自动信任重启或改端口后出现的另一个服务。

`GET /mcp` 的 `BCR-Event-Stream` 可选 parameters（默认）、console、devices；仅声明实际可用通道。
控件和设备事件有来源、代次、序号和有界库存。旧游标返回 event_gap，连接/映射改变返回新代次。
SSE 初始/reset 快照是状态，不可回放为新用户动作；反馈、回显、Agent 注入及诊断读取均有独立来源。
