# BCR2000Dev 后续规划（硬件本体检出）

建立：2026-11-12，由审查窗口整理。范围是本检出（`/Users/ethan/Documents/BCR2000Dev`）负责的设备本体与控制台界面；
Surface 模拟与 Pipe 对接在 AstroController 工作区，见其 `TODO.md`，本文件不安排那边的工作。
阶段目标仍以 [ROADMAP.md](ROADMAP.md) 为准，R1 实机条目仍在 [TODO.md](TODO.md)；本文件给出**当前可执行的顺序**。

每个条目标了三件事：是否需要设备、是否需要用户决定、依据（代码位置或实测）。没有依据的想法不列入。

## 现状（2026-11-12）

- 设备插在 ethanmacair，该机没有 USB 修复驱动，**只能收不能发**；驱动签署在 SSH 和桌面终端都失败。
  在驱动装好或设备插回本机之前，所有需要写设备的验证都做不了。详见本文件 C1 与 [连接实测清单](HARDWARE_CONNECT_TEST.md)。
- 界面打磨 1–12、14 已完成；13（连接实测）移交 B1–B3 与 `HARDWARE_CONNECT_TEST.md`，仍待设备可写。
- A1–A7 软件与文档工作已完成；六张 README 截图已更新，连接/对齐原生脚本已在中英文通过。
- 当前全量测试 5 个测试包 525 项通过；BuildWorkflow 76 项通过。各次执行结果见文末记录。
- 原界面打磨清单已删除，任务书、执行日志与 review 结论保留在 git 历史：
  `git show 80a0ef8:UI_POLISH.md`。仍有效的设备现状与未完成验证见本文件及连接实测清单。

## A. 不需要设备，可立即执行

本组已完成，以下保留各项依据、实现目标和验收条件，执行结果见文末。B–D 不随本组自动开工。

### A1（已完成） 测试汇总写进工作流（小）

- 依据：`configs/macos_workflow.py:545` 的 `test` 只转发 `swift test`，结果要人读；输出最后一行只是最后一个测试包。
  2026-11-12 因此漏报过一个持续失败的用例（R4-30）。`CONTRIBUTING.md:71` 只写“必须全部通过”。
- 做法：`macos_workflow.py test` 解析输出，打印每个 `.xctest` 包的通过/失败与总数，任一包失败或出现
  `Test Case … failed` 时返回非零；`Tests/BuildWorkflowTests` 加解析测试；CONTRIBUTING 改为引用该命令。
- 验收：人为制造一个失败用例时命令返回非零并指出包名。

### A2（已完成） 内置名称翻译补齐剩余界面（小）

- 依据：任务 3 只覆盖面板、检查器和标题栏。`BulkAssignmentView.swift:116–125`（批量分配的目标标题）和
  `OutputSettingsView.swift:38,93,131`（输出设置的参数列表）仍直接显示 `definition.name`，英文界面下是中文。
  另有两条提示文案 `ConsoleViewModel.swift:625,796` 直接内插保存的名称。
- 做法：这些显示点改用 `BuiltInNamePresentation.displayName`；不改存储值。
- 验收：英文界面下这三处不再出现内置中文名；现有测试不改。

### A3（已完成） 对齐与恢复的备份清理（小）

- 依据：`ConsoleViewModel.saveBackup`（`ConsoleViewModel.swift:1019`）在每次打开对齐窗口读取预设后都写一个
  `Backups/temporary-preset-<时间戳>.syx`，即使用户只看预览不写入；没有任何清理。每个约 15 KB。
- 做法：内容相同的备份不重复写（按内容哈希命名或先比对最近一份）；只保留恢复点引用的那一份加最近 N 份。
  不删除不是本功能写的文件。
- 验收：连续打开预览三次只多出一份备份；恢复点引用的文件永不被清理；测试覆盖。

### A4（已完成） 对齐/连接窗口的可访问性标识与自动化验收（中）

- 依据：`PresetAlignmentSheet.swift` 与 `HardwareConnectionSheet.swift` 没有任何 `accessibilityIdentifier`，
  `tools/verify_*_ui.py` 的原生验收脚本无法稳定定位这两个流程；`docs/UI_ACCEPTANCE.md` 也没有覆盖它们。
- 做法：给两个窗口的按钮、选项和进度加稳定标识；用隔离的假设备（已有 `PresetDevice`/`StartupMIDI` 测试替身的思路）
  写一个 `tools/verify_connection_ui.py`，覆盖：弹窗出现、拒绝、读取连接、对齐预览不写入、写入、恢复。
- 验收：脚本在无设备的隔离实例中通过；`docs/UI_ACCEPTANCE.md` 增加一行。运行需要辅助功能权限，脚本本身可先写好。

### A5（已完成） README 与截图（中，需要屏幕录制权限）

- 依据：`docs/images/*.png` 是 2026-11-11 的旧面板，没有显示屏、右侧设备列、设备菜单。
- 做法：用 `tools/capture_readme_screenshots.py` 重新截图并更新 README 的功能描述（连接确认、对齐预设、显示屏）。
- 本轮权限：调用宿主的辅助功能与屏幕录制预检均通过，已实际生成并检查六张截图。
  其他终端运行截图脚本仍需获得各自的系统授权；命令见 README。

### A6（已完成） 显示屏细节（小）

- 依据：`BCRDisplayModel.holdSeconds = 0.8` 是估计值（用户反馈“真机更快”，未测量）；跑马灯图案按用户口述
  “|____| 逆时针，上方合上口”实现，未逐帧核对。
- 做法：把保持时间与跑马灯帧序做成可在一处调整的常量并写明来源；等设备可用时在 B 组测量。现在不改数值。

### A7（已完成） 文档收尾（小）

- 已将旧清单的远端设备现状、未完成连接/灯光验证归入本文件与 `HARDWARE_CONNECT_TEST.md`，删除旧清单。
  README 截图（原 12）由 A5 完成；连接实测（原 13）仍待 B1–B3。
- `TODO.md` 状态区补充：连接确认、对齐预设、显示屏、设备列、内置名称翻译、确认状态查询。
- `docs/CONTROL_MAP.md` 的“右侧控制列”一节更新为现状（设备键分组、锁图标、分组圆点、IN 灯、设备菜单）。

## B. 需要设备（设备可写之后）

前置：先完成 C1（远端驱动）或把设备插回本机。顺序按依赖排列。

### B1 连接流程实测（HARDWARE_CONNECT_TEST.md A–E）

先开软件再插、读硬件、拔插、插着启动、按键。重点：确认前设备无任何变化。约 15 分钟。

### B2 对齐后的行为实测（F 的剩余部分）

对齐已做过一次且通过。剩余：勾选“启用实体按键的已分配功能”后按 B2-1（使能）等键是否执行；
锁定后界面锁图标是否出现；恢复后是否消失。

### B3 Agent 按键灯（G）

关闭闪烁时，0/8/20/40/72/96/127 各值下 B1 灯是否点亮及阈值；打开闪烁后五种节奏能否分辨、设备是否卡顿。
结果决定闪烁是否改为默认开启（现在默认关闭，原因就是这条没测）。

### B4 显示屏核对

测量数值保持时间（现为 0.8 秒估计）；跑马灯图案逐帧描述；按键 `on`/`oFF` 的显示时长；
计数式按键显示的数值。据此修正 `BCRDisplayModel`。

### B5 TODO.md 的 R1 条目

HW0（-304 复现频率、Port 2/3 用途）、HW1（按键逐个核对；对齐后 52 个按键身份已全部存在）、
HW2（回显延迟，决定 `echoWindow` 180 ms 是否保留）、HW4（拔插、休眠唤醒）、HW5（真机转动 → MCP 读值）、
HW6（高速转动的速率与 30 分钟 soak）。HW3 见 D2。

### B6 未校准的灯环模式

`LEDRingMode` 的 `spread`、`qual`、`cut`、`damp` 仍返回未知，`bar/off` 模式未核对。
`bar/pan` 已完成 24 个测试值逐灯对照，尚未做全部 128 值扫描。
做法与 2026-11-12 的 bar/pan 校准相同：临时把一个旋钮设为该模式，发 3 组各 8 个值，用户读灯。
只有在打算让对齐功能使用这些模式时才需要做。

## C. 远端设备

### C1 ethanmacair 的 USB 修复驱动（需要用户在该机桌面）

- 设备自 2026-11-12 起插在 ethanmacair（SSH 可达，登录用户 henrykang，仓库 `~/Documents/BCR2000Dev`）。
  系统识别到 USB 与 MIDI 端口，但只读身份查询无回复；尚未安装 BCRDescriptorProbe 描述覆盖驱动，OUT 包长仍为 4。
- 已只读采集 USB 描述到该机忽略目录 `build/original-usb-report.json`，编译 override 候选并生成
  `build/driverkit-probe/xcode-override` 工程，签署团队沿用该机上次 control 构建。
- 阻塞：dext 签署报 `errSecInternalComponent`，SSH 会话和该机桌面终端均失败；宿主 App 尚未生成，
  没有安装或激活任何扩展。驱动可用前远程开发只有“只听不发”的价值，C2 尚未开工。
- 排查顺序（都在该机桌面执行）：
  1. `security find-identity -v -p codesigning` 确认开发证书带私钥；
  2. 用任意小文件试签：`codesign -s "<证书 SHA-1>" -f /tmp/test`，若同样报错，说明是钥匙串对 codesign 的私钥访问
     授权问题：在“钥匙串访问”里对该私钥允许 codesign，或 `security set-key-partition-list`（需要登录密码，由用户执行）；
  3. 若试签成功而 xcodebuild 失败，在 Xcode 图形界面打开 `build/driverkit-probe/xcode-override/` 的工程构建一次，
     让它处理描述文件（该机可能未注册在开发者账号的设备列表）。
- 之后按 `docs/DRIVERKIT_USB_PROOF.md` 的复核顺序：安装宿主、系统设置里允许、重新枚举、只读身份查询有回复。

### C2 远程开发方案（中到大，依赖 C1；需要用户决定是否值得）

- 参照 `XTouchCompactDev` 的 `tools/remote_hardware.py` + `XTouchRemoteMIDI`：远端桥接进程经 SSH 标准输入输出转发
  原始 MIDI，本机生成名字含“BCR2000”的虚拟端口，App 像对待 USB 设备一样自动选中；不开端口，认证靠 SSH。
- BCR 特有的风险，开工前先测：长 SysEx 经 SSH + Tailscale（XTouch 实测约 110–125 ms）后，读预设（554 帧，
  本地 15.4 秒）与逐行确认的写入（每行等 ACK，超时 2 秒）会变慢多少、会不会超时。
- 可分两步：先做“只听不发”（不依赖 C1，可验证输入与显示屏逻辑），再做双向。
- 远端证据只算开发数据，不能替代 USB 直连的 R1 验收。

## D. 需要用户决定

### D1 对齐功能的默认选项

“启用实体按键的已分配功能”默认关闭。B2 通过后是否改为默认开启，由用户决定（开启后按实体“使能”键会立即生效）。

### D2 高精度与相对模式旋钮（HW3）

软件已支持 14-bit NRPN 与 Relative 1/2，但设备预设里 56 个旋钮都是普通绝对 CC。对齐功能现在只改按键、灯环和锁定
（`BCRPresetAlignment.swift` 不含编码器输出方式）。是否让对齐功能把指定旋钮改成 NRPN 或相对模式，需要用户决定：
它会改变旋钮手感与数值范围，需要在场确认。决定做的话，属于 A 组的开发加 B 组的实测。

### D3 无界面服务的连接策略

`BCRProviderService` 没有启用连接确认，连接后仍自动整体回写。它没有界面可弹窗。选项：保持现状；
或增加启动参数显式选择“读硬件 / 写入 / 不同步”。涉及 Provider 行为，与 AstroController 的工作有交集，需要用户裁定。

### D4 启动设置文件

`hardware-startup.json` 的“初始化并连接”路径没有界面入口，只能手写文件，且切换预设后固定等待 150 ms 未实测。
对齐功能已覆盖大部分用途。选项：删除这条路径；或保留并补界面与实测。

## 下一步执行顺序

1. A 组已完成；本窗口仅本地提交，后续 review/推送按既有约定由审查窗口决定。
2. 用户回到 ethanmacair 时先完成 C1，再按 B1–B4 实测，结果写入硬件验证记录。
3. 根据 B 组结果修正软件，再由用户决定 D1–D4；C2 仍需明确是否值得投入。

## 本轮执行约束

- 本轮按用户指令完成 A1–A7；B–D 留待设备及用户决定。不连接实体设备，不发送真实 MIDI/SysEx。
- 始终在 main 验证并逐项本地提交，不建分支/额外检出，不 push、不打标签；审查窗口负责 review 后推送。
- 保留模拟侧实现、Schemas、Clients 及 Provider 合同；CONTROL_MAP 只按 A7 明确范围更新现状说明。
- 新文案成对本地化；不改既有测试断言。测试替身入口变更、失败修正与额外提交在下方如实记录。
- 以 `python3 configs/macos_workflow.py test` 汇总全部包，运行边界、BuildWorkflow、格式和相关原生验收；
  未验证项分别记录。提交号随下一次文档更新补入，末项由收尾记录补齐。

## 执行记录

### A1 — `75a86d1`（rebase 前 `6a71375`）

- 改动：macos_workflow 增加流式执行与逐包汇总；CONTRIBUTING 引用新入口；新增 test_test_summary.py。
  旧环境测试只把 mock 从 _run 移到 _run_tests，原断言保留。
- 验证：Swift 五包 517 项、失败 0；BuildWorkflow 76 项、失败 0；域边界通过。
  人造早期包失败 + 末包通过 + swift 退出 0 的日志使实际执行入口抛错，并明确显示失败包。
  缺失包、截断输出、独立 failed 用例、非零退出均有回归。
- 过程：初次回归发现旧 mock 入口不匹配及一次误替换，已纠正并完整重跑；未更改既有断言。
- 未验证/偏离：负例使用临时假 swift 输出，不改生产 Swift 测试。未连接设备。

### A2 — `7d3c607`（rebase 前 `fc7a587`）

- 改动：BulkAssignmentView、OutputSettingsView（含输出读数）以及 ConsoleViewModel 两条提示接入显示翻译。
- 验证：Swift 五包 517 项、失败 0；BuildWorkflow 76 项、失败 0；边界、strings lint、App build、
  双语 1200×760 startup smoke、英文隔离 MCP 双版本冒烟通过。既有测试未改。
- 未验证：未逐项点击英文批量分配/输出窗口；显示函数已有双向翻译与存储不变测试。
  没有存储格式、分组引用或功能逻辑变化，无设备操作。

### A3 — `9142d8c`（rebase 前 `0c134b6`）

- 改动：新增 PresetBackupStore；ConsoleViewModel 备份入口委托该值类型；新增四项存储测试和一项连续三次预览测试。
- 验证：Swift 五包 522 项、失败 0；BuildWorkflow 76 项、失败 0；边界与格式检查通过。
  初轮新测试捕获 macOS /var 路径别名导致返回 URL 不一致，修正实现后保留原断言并完整重跑。
- 策略：最近 N 取 5，另保留恢复点。SHA-256 新命名校验内容；旧时间戳命名需能解析为完整临时预设才纳入管理。
  未知文件、损坏内容、目录、符号链接不删除；读写与清理错误仍显示为失败。
- 未验证/偏离：只测试隔离目录与假设备，没有设备操作。没有既有用户数据 schema 变更；备份命名与清理属于 A3 明确范围。

### A4 — `564510a`（rebase 前 `f72c966`）

- 改动：两个 sheet 及设备菜单加稳定标识；Debug 专用 IntegrationMIDIFixture、原生 PID 级 AX 工具与
  verify_connection_ui.py；mcp_integration 显式 fixture 开关；UI_ACCEPTANCE 增加入口和隔离边界。
- 验证：Swift 五包 523 项、失败 0；BuildWorkflow 76 项、失败 0；边界、strings lint、App build、双语 startup smoke 通过。
  原生脚本在中英文 1200×760 下均通过：拒绝/读取、三次预览不写设备且备份唯一、选项切换、写入进度、回读、恢复。
  普通实例单独使用 fixture 参数退出 2，未初始化 MIDI。对应隔离产物：case-hff9li_8、case-c81086b6。
- 过程/偏离：AppleScript 逐元素遍历超时，改用自动编译的 Swift 6 AX 查找辅助器；窗口操作仍经 System Events。
  不改真实驱动、Provider 合同或普通隔离模式；没有实体 MIDI/SysEx IO。未验证配置文件驱动的“初始化并连接”分支。

### A5 — `9426613`（rebase 前 `bf7af6f`）

- 改动：README 功能/连接/显示说明及六张截图；NativeUI 增加仅捕获本进程主窗口的方法，连接脚本增加显式截图模式。
- 验证：六张 1680×900 PNG 均逐张检查；四张 Mock 截图和两张假设备截图通过实际屏幕录制生成，脚本完整通过。
  本机辅助功能、屏幕录制预检均为 true。合并远端后 Swift 五包 525 项、失败 0；BuildWorkflow 76 项、失败 0；
  边界、格式、命令、compileall、App build、双语 startup smoke 和假设备原生连接验收通过。
- 同步：rebase 到 edae4d4 并按锁更新 SurfacePlugins 到 6071354；随后又合入仅修改模拟启动文档的 6acc14b。
  上方 A1–A4 编号更新为最终 rebase 后编号；各项原始测试数保留，525 为合入远端后的结果。
- 过程/偏离：首次补图任务与前一截图任务短暂重叠，发生端口冲突，已串行重跑通过；截图共新增两张流程图，
  明确标注内存假设备，不作为实机证据。没有拍摄其他窗口或桌面，没有真实 MIDI IO。

### A4 补充 — `ec225b4`

- 补跑复现一次“恢复进度未出现”：实际已完成，但 AX 查询错过短暂进度态。
  脚本现在接受进度或完成态作为启动证据，随后仍要求完成控件、精确写入次数和恢复哈希一致。
- 中文、英文原生验收串行重跑通过（case-xfjejwu1、case-_75cwihp）；没有改变应用或设备逻辑。

### A6 — `67d4274`

- 改动：BCRDisplayModel.Calibration 集中保持时间、动画速率和帧序；SurfacePanelView 读取同一速率。
  保留 holdSeconds 兼容入口；注释注明 0.8 秒为估计值、12 Hz 未计时、帧序来自用户口述。
- 验证：Swift 五包 525 项、失败 0；既有显示测试不改；BuildWorkflow 76 项、边界、build、双语 smoke 通过。
  中英文假设备原生验收通过。A4 瞬态进度问题另用 ec225b4 修正并独立记录，没有混入显示逻辑提交。
- 未验证/偏离：没有设备计时或逐帧校准，数值与正时间域内的显示顺序未变；仍按 B4 待实测。

### A2 补充 — `153c0a3`

- 最终显示点核对补齐 BulkAssignmentView 的分组选择器、WorkspaceTabsView 的参数/分组与导入确认、
  SurfaceProgramsView 的宏参数选择器。均为显示层调用；配置库元数据保留原文。
- 新增 verify_builtin_names_ui.py：在英文隔离实例中保存 8 个中文参数名与中文分组，实际浏览工作区、输出设置、
  批量分配预览；英文显示通过，配置 JSON 字节不变，MCP 仍返回中文原名（case-2dsalk9j）。
- Swift 五包 525 项、失败 0；BuildWorkflow 76 项、失败 0；边界和 App build 通过。
  现有测试断言未改，保护参数定义未改。初轮脚本尝试修改使能定义被正确拒绝，另一次误选样本分组，修正脚本后通过。
- 与初稿偏离：自查时发现上述同类漏点，按 A2 的“剩余界面”目标一并补齐，未引入名称存储或业务逻辑变化。
