# Codex 后端

设置 → Agent 中选择 Mock / Codex。默认 Mock；选择 Codex 不会自动连接或启动任务。
填写本机 `codex` 可执行文件与绝对工作目录，点击连接后选择模型、推理强度与任务内容。
在 Agent 页或绑定实体/虚拟按键上明确启动某个槽位。8 个槽位各有独立 Thread，完成后再次启动沿用该 Thread。
断线、全部停止、切回 Mock 后不恢复旧任务；重新连接建立新会话。

默认只读。启用工作目录写入时，writableRoots 必须严格等于解析后的工作目录，不允许放宽为父目录。
网络权限不随工作目录写入开启。CLI 使用本机已有的 Codex 登录，App 不复制或保存登录令牌。
连接只执行 initialize、account/read、model/list；不会开始推理。模型来自实时列表，不硬编码可用权限。
路径、任务与权限是本次会话设置，不因重开应用自动执行。模型目录缓存位于独立本机配置目录。

审批在 Agent 页显示命令、工作目录、请求原因或文件授权根等详情。批准与拒绝均绑定具体槽位和原始
RPC request ID，保留数字/字符串类型。真实后端的审批不自动过期，持续防重放；用户可充分阅读后再决定。
实体按键及槽位主操作只能打开详情，不能批准。只有已呈现的具体请求详情页能明确批准；关闭后重新查看仍需呈现。
拒绝无需先批准或等待超时，等待审批时也可独立中断。重连后旧详情页令牌不能授权复用相同 RPC ID 的新请求。
MCP 不能批准或拒绝审批。
协议错误、退出、模型不可用、非法工作目录均显示失败；不会静默切回 Mock。

## 协定依据与验收

当前核对 CLI 0.167.1 生成的稳定 schema，以及
[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)。
初始化使用 clientInfo；Thread/Turn 响应分别读取 `thread.id`、`turn.id`；turn/start 使用文本 input 数组与
显式 sandboxPolicy。只有 turn.status=completed 才算完成，failed/interrupted 分别显示错误/中断。
审批回应使用 `decision: accept/decline`。诊断不保存原始 JSONL 内容；协议通道保留原始消息。

```bash
swift test --build-path build/swiftpm --filter CodexSessionIntegrationTests
BCR_CODEX_SOAK_SECONDS=1800 swift test --build-path build/swiftpm --filter CodexSessionIntegrationTests.testProtocolAndStateMachineSoak
```

测试中的 Python mock app-server 无网络、无凭据、无 shell/仓库写入。覆盖握手、分页模型列表、Thread、Turn、
数字审批 ID、重复审批、完成/失败、中断、全部停止及新会话重连。子进程独立覆盖错误回应、提前退出、
乱序/重复回应、Malformed JSONL、UTF-8 分段、队列溢出、最终输出与退避/强制停止。
长时间测试使用真实 JSONL 子进程和墙钟时间，不以快进时间替代。

本机真实 CLI 已另行完成只读握手、account/read 和 model/list；没有发起付费/远端推理任务。

2026-11-11 长时间验收：1800.091 秒、264,873 个 Turn、八个槽位，0 失败。完整常规回归及边界见 OFFLINE_ACCEPTANCE.md。

## P0 审批修复（RV1–RV3）

审批发送采用验证 → 发送 → 提交决定，发送失败保留原请求与等待状态，允许重试；同请求发送中禁止重复提交。
同一 Turn 可有多条独立审批，只有全部回复后才恢复 running；结束/中断后的响应不会复活旧 Turn。
数字 ID 与同文本字符串 ID 互不混淆。兼容显式审批期限的调用方：过期批准转为 decline 发送，过期后仍可拒绝，
不会留下无法操作的请求。真实 App 默认不设置期限。

回归覆盖：超过旧 8 秒窗口仍可操作、显式过期后的拒绝/重新启动、单槽位多请求、发送失败重试、ID 类型冲突，
以及反复主操作不会批准、精确选择第二个请求、拒绝无需呈现、重连旧详情令牌失效。
