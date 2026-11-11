# WP3 交接：通用 MCP

> 历史交接 / 任务记录，保留当时的实现状态与验收结果；当前工作以
> [TODO](../../TODO.md) 和 [ROADMAP](../../ROADMAP.md) 为准。文中代码路径均相对仓库根目录。

本轮按用户要求连续推进 WP3–WP7；本包完成本机验收，不推送远端，保留独立检查记录。
工具、协议和验收不依赖特定厂商客户端。提交记录见本机 main 日志。

## 改动

- Core 新增 MCP 模型、工具 Schema 校验、权限/限速/审计服务和双版本路由器。
- App 新增 Network.framework 回环 HTTP、Keychain 凭据、设置面板与一键停止。
- 写入经过 SurfaceSession，MIDI 来源标为 AGENT；配置保存失败对 MCP 调用方可见。
- 配置 v2 增加 agentWritable，旧配置可见迁移，示例使能参数禁止 Agent 写入。
- Python 标准库冒烟支持现代通用 MCP 与标准旧版会话；提供显式 Debug 隔离原生验收。

## 设计取舍

以 2026-07-28 无状态协议为主，兼容 2025-11-25 握手协议。HTTP 只负责传输和鉴权，
Core 不依赖 Network、SwiftUI、Security 或 CoreMIDI。小型本机 HTTP/1.1 服务需要 Content-Length，
显式拒绝分块传输/管线请求；SSE 和 stdio 桥接不在首版范围。输入的枚举、oneOf、类型和边界在执行前校验。
配置保存失败会说明内存已更新但未持久化，不把暂存配置伪装成已保存。

重建 ad-hoc App 后，macOS 要求重新授权 Keychain，曾发现同步 SecItemCopyMatching 阻塞启动。
已改为后台读取，等待授权时 UI 不阻塞；停止后迟到的凭据不会重新启动服务，并有悬挂凭据测试覆盖。
用户已在系统弹窗授权，真实 Keychain 模式两版 MCP 冒烟通过。

后续重复验收用显式 --integration-test Debug 模式：独立数据目录、内存测试凭据、Mock-only，
不读取用户 Keychain、不连接实体 MIDI。无测试环境参数则不启动此模式；Release 拒绝该模式。

## 检查与操作

- Swift：95 条 Core + 20 条 Console 测试通过（本包新增 23 条），无新增编译警告。
- BuildWorkflowTests：19 条通过。
- 命令配置校验、compileall（configs/tools）、workflow help、diff --check 通过。
- App build、签名检查、原生 startup smoke 通过。
- tools/mcp_smoke.py 与 --legacy 均在真实运行的 App 上通过：发现/初始化、工具列表、
  参数写入读回、保护参数拒绝、批量原子性、401、非法 Origin。
- tools/mcp_integration.py 的隔离原生验收同样通过两版 MCP，结束自动关闭测试 App。
- 1200×760 内容区打开设置；MCP 写 J1=90，检查器显示 90°、Mock P1-1 LED 95；
  旋钮增加一格后 MCP 读到新值。一键停止后连接失败，固定端口重启成功。
- 真机 MIDI、其他厂商 SDK、分块 HTTP、SSE 未做，不宣称验证这些扩展。
- 实际 token 与 Keychain 密码未进入代码、文件、日志或工具输出。

## 新增测试名单

- MCPTests.testToolSchemasAndReadToolsAreClientNeutral
- MCPTests.testAgentWriteClampsUpdatesMockAndMarksOrigin
- MCPTests.testProtectedParametersReadOnlyAndAtomicBatchFailures
- MCPTests.testBatchSuccessDuplicateAndUnknownParameterFailures
- MCPTests.testConfigurationToolsRequirePermissionAndValidateBeforeChangingState
- MCPTests.testWriteRateLimitUsesInjectedClockAndCountsBatchMembers
- MCPTests.testAuditIsBoundedAndDoesNotRetainRequestArguments
- MCPTests.testModernDiscoveryToolCallsAndVersionMetadata
- MCPTests.testHeaderMismatchMalformedRequestsAndUnsupportedVersionsAreExplicit
- MCPTests.testLegacyHandshakeSessionExpiryAndStop
- MCPTests.testConfigurationPersistenceFailureIsReturnedToMCPCaller
- MCPTests.testNestedSchemasRejectUnknownPropertiesAndFractionalControlIDs
- MCPTests.testV1ParameterMigrationProtectsEnableAndRoundTripsV2
- MCPHTTPServerTests.testLoopbackModernDiscoveryWriteReadAndSourceAttribution
- MCPHTTPServerTests.testAuthenticationOriginHostAndModernHeaderValidation
- MCPHTTPServerTests.testLegacySessionHeaderNotificationAndDeletion
- MCPHTTPServerTests.testOccupiedPortFailsVisiblyAndStopClosesListener
- MCPHTTPServerTests.testPendingKeychainReadLeavesMainActorResponsiveAndStopPreventsLateStartup
- MCPHTTPServerTests.testV1ConfigurationMigrationIsVisibleAndDoesNotOverwriteSource
- MCPHTTPServerTests.testParserRejectsSmugglingAndWaitsForCompleteBody
- MCPHTTPServerTests.testSettingsDefaultOffAndCredentialIsNotTouchedForReadOnlyConfiguration
- IntegrationTestContextTests.testContextUsesOnlyItsExplicitDirectoryAndInjectedCredential
- IntegrationTestContextTests.testInvalidIntegrationEnvironmentFailsInsteadOfUsingUserData

## 待验证与审查重点

实体设备仍待 R1；本包未增加设备行为假设。重点审查鉴权/Host/Origin/帧边界、现代与旧版元数据隔离、
批量全部校验后写入、配置持久化失败语义。WP4 继续整体配置校验与无损导入；WP6 接入统一输出安全门。
