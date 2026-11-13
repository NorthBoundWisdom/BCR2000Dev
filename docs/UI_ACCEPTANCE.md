# 原生 UI 验收

这些脚本验证当前 SwiftUI 界面的完整交互，保留作为人工发布前或相关 UI 改动后的验收入口。
无需实体 BCR2000；它们不是无界面的单元测试，也不代替 [R1 实机验证](HARDWARE_VALIDATION.md)。

## 运行方式

先在仓库根目录构建 Debug App：

```bash
python3 configs/macos_workflow.py build
```

在已登录且解锁的 macOS 图形会话中，逐个运行下面的命令。启动命令的终端 / Agent 宿主需要
“系统设置 → 隐私与安全性 → 辅助功能”权限；前台按窗口截图还需要屏幕录制权限，离屏自身渲染不读取桌面像素。
不并行运行，以免共享 MCP 端口或键盘焦点相互干扰。

```bash
python3 tools/mcp_integration.py --connection-fixture --script tools/verify_connection_ui.py
python3 tools/mcp_integration.py --language en --configuration-write --script tools/verify_builtin_names_ui.py
python3 tools/mcp_integration.py --offscreen --configuration-write --script tools/verify_language_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_configuration_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_endpoint_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_functions_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_output_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_precision_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_review_fixes_ui.py
```

## 离屏能力（2026-11-13）

本机有人使用桌面时，所有可离屏场景必须显式加 `--offscreen`。不发送系统键盘事件，不激活 App，不打开访达。
只有必须前台的脚本保留原前台步骤；本轮未在当前桌面运行这些场景，离屏请求会在进入验收步骤前明确拒绝。
因此带 `--script` 的默认值继续为前台，不自动改成离屏。

| 脚本 | 模式 | 语言与依据 |
| --- | --- | --- |
| `verify_connection_ui.py` | 可离屏 | 中英文；离屏专用非激活面板承载原有连接/对齐视图、菜单和确认动作，全部状态断言保留；系统原生菜单/确认框的呈现仍由原前台路径验证 |
| `verify_language_ui.py` | 可离屏 | 中文启动，通过实际设置控件在同进程切换中英文；主窗口、设置、窗口标题、设置菜单、参数/名称/配置保留及桌面审计通过 |
| `verify_builtin_names_ui.py` | 可离屏 | **英文专用**，保留原英文断言；中文实例不适用该既有验收语义 |
| `verify_endpoint_ui.py` | 可离屏 | 中文；端点默认值/禁用状态与自身 sheet 渲染通过 |
| `verify_functions_ui.py` | 可离屏 | 中文；步进/指定/循环、批量分配和保留参数值通过 |
| `verify_review_fixes_ui.py` | 可离屏 | 中文；MCP 保护、复位跳过报告、大角度 Canvas 自身渲染通过 |
| `verify_configuration_ui.py` | **必须前台** | 产品文件面板主动 activate/makeKeyAndOrderFront，且路径选择依赖系统键盘；本轮保留原验收步骤，未前台运行 |
| `verify_output_ui.py` | **必须前台** | 不聚焦时 AXSetValue + AXConfirm 未提交动态端口，原连接状态断言失败；保留原 Tab 提交和全部输出验收步骤 |
| `verify_precision_ui.py` | **必须前台** | 不聚焦时 AXSetValue + AXConfirm 未提交 0.25 步长，原步长断言失败；保留原 Tab 提交和全部精度验收步骤 |

示例（逐个运行，不并行）：

```bash
python3 tools/mcp_integration.py --offscreen --connection-fixture --script tools/verify_connection_ui.py
python3 tools/mcp_integration.py --offscreen --configuration-write --script tools/verify_endpoint_ui.py
python3 tools/mcp_integration.py --offscreen --configuration-write --script tools/verify_functions_ui.py
python3 tools/mcp_integration.py --offscreen --configuration-write --script tools/verify_review_fixes_ui.py
python3 tools/mcp_integration.py --offscreen --language en --configuration-write --script tools/verify_builtin_names_ui.py
```

每次离屏运行在启动前开始有限采样，关闭后保存 `desktop-audit.json`：仅记录前台/辅助功能焦点 PID 和本测试进程的窗口元数据，
不读取其他应用像素。若目标进程抢焦点或出现与真实屏幕相交的非透明窗口，采样器立即结束该测试实例并使验收失败。
`foregroundStable` 如为 false，须结合 PID 判断是否用户自行切换；不能声称该次前台应用全程未变。

透明窗口的 WindowServer 筛选未能取得可截取的主窗口号，已实际验证端点场景；离屏截图使用 Debug 隔离 App 自身
`cacheDisplay`，保存当前主视图、当前 sheet 或离屏交互面板，不包含其他窗口、桌面像素或窗口边框。接口只在显式隔离 Debug 进程注册，
不新增产品 UI 或 Provider 工具。前台截图也改为限定本进程窗口号，不再按屏幕区域截取。

`mcp_integration.py` 为每次运行复制一个有唯一进程身份的 App，使用临时配置、内存凭据与
Mock 机械臂示例预置，不读取生产配置或 Keychain，不启动实体 MIDI。
每次先在运行中的 App 上执行现代 / 兼容协议的 `mcp_smoke.py`，再执行指定脚本，结束后退出该实例。
配置写入权限仅用于隔离验收，不改变用户服务权限。
`--connection-fixture` 额外注入 Debug 专用的内存 MIDI 替身并允许隔离实例切换来源；不会创建 CoreMIDI 端口，
只将计数与预设哈希写到该次隔离目录的 `connection-fixture.json`。普通隔离模式仍禁止实体 MIDI。
稳定标识查找由 `native_ui.swift`（首次运行自动编译到忽略目录 build/tools）按 PID 执行；
辅助功能权限错误会立即失败，找不到标识与控件无法操作分开报告。
该模式的 hardware 标签代表测试替身，不是实机证据；单独传给普通实例会拒绝启动。
隔离实例默认使用简体中文，以保持现有脚本的文字选择器稳定；可用 `--language en` 验证英文 MCP。
此语言覆盖只作用于测试进程，不修改用户偏好。

双语改动已通过两种语言的 1200 × 760 原生启动与 MCP 冒烟；下表保留原六项脚本的历史结果，
新增连接脚本为 2026-11-12 中英文实际点击验收；内置名称脚本为英文界面配中文存储的实际浏览验收。
本次新增中英文原生视图渲染快照检查（主窗口最小 1200 × 760 以及各设置页）；
设置意图由聚焦测试验证。完整辅助功能点击脚本仍保留为人工发布验收入口，未冒充本轮已执行。

脚本将窗口设为 1200 × 760，并通过辅助功能执行交互；界面结构或语义 help 变化后需同步维护选择器。
失败返回非零状态，不应记作通过。日志、导出配置、辅助功能树与部分截图保存在
被 Git 忽略的 `build/mcp-integration/case-*`，排查时查看该次目录。

## 覆盖范围与最近验收

| 脚本 | 覆盖范围 | 最近验收 |
| --- | --- | --- |
| `verify_language_ui.py` | 同进程中文→English→中文即时切换；原生设置及应用设置命令更新，MCP参数值/用户命名/磁盘配置不变 | 2026-11-13 离屏通过 |
| `verify_builtin_names_ui.py` | 中文存储的参数/分组在英文工作区、批量预览、输出设置中翻译；浏览不改 JSON/MCP 原名 | 2026-11-12 通过 |
| `verify_connection_ui.py` | 连接确认/拒绝/读取；三次预览零写入且备份去重；分类汇总/展开/收起、选项、写入进度、单键功能确认/取消/启用/禁用、回读及恢复 | 2026-11-13 中英文通过 |
| `verify_configuration_ui.py` | 参数草稿刷新 / 冲突解决；原生导入导出；非法文件拒绝；替换确认及保留硬件映射 | 2026-11-11 通过 |
| `verify_endpoint_ui.py` | MIDI 端点设置；默认自动 Port 1；隔离模式禁止应用实体端口 | 2026-11-11 通过 |
| `verify_functions_ui.py` | 步进 / 指定 / 循环按键；参数吸附；整行分配预览确认及保留运行值 | 2026-11-11 通过 |
| `verify_output_ui.py` | 本机 OSC 仿真；使能、限速、停机；实际 LED；接收端断线 / 重启后重新使能 | 2026-11-11 通过 |
| `verify_precision_ui.py` | 相对 1 / 2、每格步长编辑；Mock NRPN 回路与 14-bit 读数 | 2026-11-11 通过 |
| `verify_review_fixes_ui.py` | MCP 保护使能参数；复位跳过报告；启用可选机械臂预览及极大有限值渲染 | 2026-11-11 通过 |

2026-11-11 OSC 验收中，接收端丢失后 309 ms 内告警；它是本机仿真结果，不代表真实机械臂的停机保证。
端点脚本仅验证隔离界面与默认选择；实际设备枚举、手动路由和 USB 重连仍按 R1 验收。

新增非硬件验收入口：CodexSessionIntegrationTests、CodexAgentControllerTests、SurfaceProgramsTests、
FeedbackSchedulerTests、JSONParameterLinkTests、WebSocketParameterAdapterTests，以及
`tools/verify_parameter_events.py` / `tools/verify_stdio_bridge.py`。
原生 Debug 视图快照输出到忽略的 build/ui-validation。2026-11-12 已通过屏幕录制权限更新 README 的四张 Mock 截图，
并以 `BCR_CAPTURE_README=1` 运行连接验收脚本生成两张假设备截图；具体复现命令见 README。

使用 `BCR_UI_CAPTURE_DIRECTORY=build/ui-validation/connection` 运行连接脚本，可将 1200×760 的连接与对齐窗口截图
保存到忽略目录；`BCR_CAPTURE_README=1` 仍以 1680×900 更新 README 图片。两种模式只捕获隔离 App 自身窗口。

## 离屏维护说明

不可见性由窗口透明和鼠标穿透提供，App 使用 accessory 策略并避免主动激活。屏幕外坐标是首次隐藏时的尽力放置，
SwiftUI 后续可能将 frame 约束回屏幕范围，因此不能只用坐标判断不可见。
维护使用 AppKit 的应用更新、窗口更新/移动/尺寸/屏幕及 sheet 通知。通知处理不持续追逐已透明窗口的坐标，
避免形成同步 frame 约束循环。不再运行测试 App 内 50 ms 常驻轮询。
桌面审计器的 50 ms 采样只在一次验收期间运行，用于观测与及时终止不合格测试进程。

### 菜单与连接流程的离屏呈现

原生菜单可能取得辅助功能焦点而不改变 NSWorkspace 的前台 PID；只看前台 PID 不够。
审计现同时检查系统级 AXFocusedApplication，目标获得焦点立即失败；完全没有有效焦点读数也拒绝通过。
短暂读取失败会记录在 focusReadFailures 中，有限采样不能保证观测到两次采样之间的所有瞬间。

仅在显式测试模式的 --offscreen 进程，连接/对齐 sheet、设备预设/专业面板/批量参数组菜单与按键功能确认共用不能成为 key/main 的
nonactivatingPanel。连接和对齐仍使用原产品视图；菜单和确认复用原动作、文案、禁用条件与标识，所有原验收断言保留。
另外只在该进程的 NSApplication 具体类上拦截两个公开 activate 请求，防止视图桥接显式激活。
普通产品启动与前台验收继续使用原生 Menu/sheet/confirmationDialog，不改变存储格式、Provider 合同或业务动作。
离屏验收覆盖真实视图与动作，不验证系统原生菜单/确认窗口的呈现机制；这部分仍需原前台路径验收，本轮没有前台运行。
