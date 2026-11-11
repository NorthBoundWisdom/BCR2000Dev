# Provider 1.0 本地交付验收

日期：2026-11-11。基线 `bf73a5f2d5098e00f3f92ea837ebda1a51fc9a8a` 加保留的未提交增量。
本次是本机候选交付，无 commit、push、tag 或公开 release。适用 macOS arm64；未构建 universal 发布包。

`TODO_DOMAIN_INTERFACES.md` 共 43 项，首批软件范围完成 41 项；C03、C05 的实体复验未完成。
机器人/底盘只提供独立、可选、显式 simulation 的参考模型，真实执行器、厂家协议、碰撞/动力学资格均不支持。

## 可复核产物

证据根目录为忽略的 `build/domain-refactor/20261111T102648114708Z/`。本地 profile、凭据、
MIDI 原始数据和生成的程序不进入版本库。重构前工作树备份在该目录 `before*`，失败尝试日志保留。

最终候选 `artifact-05/` 包含可执行服务、相邻资源 bundle、离线 profile 工具、SDK 1.0.0 zip、
原生诊断 CLI、示例、Schema 与接口文档。其 `manifest.json` SHA-256 为：

```text
aca7e2112531acc1d1ccf0f6c361107ca06df2da21bfb3bc32511ab4be881ad8
```

manifest 为 dirty=true、debug、本地 handoff，逐文件记录 SHA-256；它不声称代码已提交。
资源加载支持相邻 bundle，验收设置 `BCR_PROVIDER_PACKAGED=1` 且在临时工作目录启动，禁止依赖源码目录。
只用公开 SDK/CLI 接线；消费方不需要导入 Swift 内部模块、内部 Python 文件或查看仓库源码。

## 软件验证

| 验证 | 结果与证据（相对证据根目录） |
| --- | --- |
| 构建/依赖方向 | `configs/check_domain_boundaries.py` 验证 18 个模块及领域无 UI/MCP/CoreMIDI/具体 Agent 依赖；Schema 副本一致 |
| 全量 Swift | `full-swift-tests-05.log`：355 个 XCTest，0 失败（领域 22、适配 9、旧 Core 230、GUI/传输 94） |
| 构建工作流 | `build-workflow-tests.log`：52 个，0 失败 |
| 公开 SDK | `public-sdk-tests.log`：6 个，0 失败；无 proxy/redirect、pin、畸形响应、凭据反射及 EOF |
| 事件流 | 全量含 `sse-tests-final-02.log`：8 个，覆盖参数背压、console 100 条有序合并、跨代次隔离、513 条断流及参数/console/devices 观察者释放 |
| 供应方发布件黑盒 | `blackbox-final/summary.json`：14 组通过，全部新工具响应独立校验公开 Schema |
| macOS 原生程序 | `native-build-final.log`：debug .app 构建、签名及框架验证；`native-smoke.log` 中英启动通过 |
| 程序化界面 QA | `ui-final-en/`、`ui-final-zh-Hans/` 各 10 张 AppKit 渲染 PNG 与同名语言日志；新增 MCP 权限和操作按钮中英均无裁切，Root 已复核 |

供应方黑盒覆盖发现/鉴权/未知能力、错误实例 RPC/SSE pin、来源与反馈区分、映射代次/过旧游标、
显式写保护、错误版本/资源/frame/单位字段无副作用拒绝、未知位姿、旧 token/序号、限位、
实际关节/FK、Ackermann 实际运动/停止、独立时钟与故障/重置、凭据不入快照、设备 SSE、
无 console/GUI/Agent/状态轮询的实时时钟失效停机。

有意义的安全回归还覆盖：到 lease/命令边界立即停止、stopping 期间禁止重新 enable/drive、
停止时不继续转向、权限撤销废止旧控制并自主停稳、恢复权限不恢复目标、页面/映射切换不把旧输入
标成新 generation 的 accepted 操作。各类成功响应均与实际终态分开核对。

## 分类证据与剩余范围

| 类别 | 本轮结论 |
| --- | --- |
| 参数写入/反馈请求 | 软件回读与 Mock 闭环通过；不表示灯环已被人观察 |
| 模拟运动与停止 | 参考关节链/Ackermann 按模型实际推进通过，source=simulation |
| 外部接线 | 独立消费方只读 artifact-05 复核双实例 pin、故障 unknown、同端口重启拒旧实例、已接受 move/stop 丢响应后不重放；最终消费者证据由其仓库保存 |
| 公开原生诊断 | 自包含 CLI 和 begin/end/abort、实例 pin、回读隔离软件验证通过；未在实体 BCR 上运行本轮完整 snapshot |
| 真实控件输入 | pending：系统只发现 X-TOUCH COMPACT，未拿其冒充 BCR；等待 BCR 重新连接后复验绝对离散阈值和真实来源 |
| 物理断插/重连 | pending：缺少本轮 USB 断插与重连记录，C05 保持未勾选 |
| Relative/NRPN | 软件编码支持与测试存在，当前实体预设未资格化，能力清单明确标记 |
| 持续高频/长时性能 | 本轮仅约定本机正常调用/观察 2 s 预算与明确有界队列；不声称持续硬件吞吐或长时资格 |

Root 已准备独立 generic profile 和新 data-dir，仅在硬件恢复后才启动硬件 provider；旧 App 已通过
公开接口切 Mock，避免两个 writer 争抢设备。既有 R1/HW 待办继续有效，不用模拟/软件结论替代。

旧 Core 导出、旧开发工具入口及旧配置迁移保留兼容。旧版示例保护迁移到显式配置策略，
默认控制台领域配置保持中性。具体业务映射、流程、审批和部署均归外部消费方。
