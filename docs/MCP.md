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
未实现的方法返回 -32601；现代版同时返回 HTTP 404。GET 不提供 SSE，返回 405。
没有广告订阅、MRTR 或 SSE 能力。现代版元数据错误返回 400/-32020，不支持版本返回 400/-32022。

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
- 参数还必须允许 agentWritable；示例 arm.enabled 默认不允许 Agent 写入。
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
| reset_group | group: string | 该组所有参数的写入结果；任何参数不可写则整组拒绝 |
| list_controls | 空对象 | 108 个 control、label、assignment、binding、value |
| assign_control | assignment: 完整功能分配对象 | 保存后的分配，需要配置写入 |
| create_parameter | definition: 参数定义对象 | 创建后的参数信息，需要配置写入 |
| update_parameter | definition: 参数定义对象 | 更新后的参数信息，需要配置写入 |

所有 inputSchema 都是 object、additionalProperties=false，required 字段见上表。
参数定义包含 id/name/group/unit/minimum/maximum/defaultValue/kind/agentWritable/step；
id 和 name 必需，其余默认与 App 创建参数一致。update_parameter 接收完整定义，不是补丁。
step 可缺省或为 null（不吸附），启用时为正数；kind 是 continuous 或 toggle；数值必须有限，minimum < maximum，默认值在范围内。
参数信息另包含 value、writable 和绑定的 controls。

控件使用 section、row、index，范围由 section 决定。分配包含 control、target、
buttonBehavior（toggle/momentary）和 inverted。target 与版本化 SurfaceConfiguration 共用 JSON 编码。
例如给 E1-1 绑定 J1：

    {"assignment":{"control":{"section":"encoder","row":1,"index":1},
      "target":{"parameter":{"_0":"arm.j1"}},"buttonBehavior":"toggle","inverted":false}}

准确的枚举分支与字段范围也由 tools/list 的嵌套 oneOf schema 提供。

## 通用客户端验收

在 MCP 设置中启用服务并复制 token；只把凭据放入本机环境变量，不要将它写到命令文件或仓库。

    export BCR_MCP_TOKEN='<从设置复制的 token>'
    python3 tools/mcp_smoke.py
    python3 tools/mcp_smoke.py --legacy

脚本仅使用 Python 标准库，执行发现/初始化、tools/list、写入与读回、保护参数拒绝、批量原子性、
错误 token 与非法 Origin 检查。它恢复原参数值并清理旧会话，不打印凭据。
MCP 设置里的“复制连接命令”给出通用 curl server/discover 请求，不需要特定 Agent CLI。

当前配置 v3；v1→v2 新增 agentWritable，v2→v3 新增 step 和触发参数功能。旧定义缺省为可写，arm.enabled 缺省不可写；
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
