# BCR2000Dev 后续规划（硬件本体检出）

建立：2026-11-12，由审查窗口整理。范围是本检出（`/Users/ethan/Documents/BCR2000Dev`）负责的设备本体与控制台界面；
Surface 模拟与 Pipe 对接在 AstroController 工作区，见其 `TODO.md`，本文件不安排那边的工作。
阶段目标仍以 [ROADMAP.md](ROADMAP.md) 为准，R1 实机条目仍在 [TODO.md](TODO.md)；本文件给出**当前可执行的顺序**。

每个条目标了三件事：是否需要设备、是否需要用户决定、依据（代码位置或实测）。没有依据的想法不列入。

## 现状（2026-11-12）

- 设备插在 ethanmacair，该机没有 USB 修复驱动，**只能收不能发**；驱动签署在 SSH 和桌面终端都失败。
  在驱动装好或设备插回本机之前，所有需要写设备的验证都做不了。见 [UI_POLISH.md](UI_POLISH.md) 的“远端设备”一节。
- 界面打磨 1–11、14 已完成；12（README 截图）与 13（连接实测）未做。
- 全量测试 5 个测试包 517 项通过（含本次 review 的回归测试）。

## A. 不需要设备，可立即执行

按价值排序。A1–A4 是 review 或自查发现的实际缺口，建议优先。

### A1 测试汇总写进工作流（小）

- 依据：`configs/macos_workflow.py:545` 的 `test` 只转发 `swift test`，结果要人读；输出最后一行只是最后一个测试包。
  2026-11-12 因此漏报过一个持续失败的用例（R4-30）。`CONTRIBUTING.md:71` 只写“必须全部通过”。
- 做法：`macos_workflow.py test` 解析输出，打印每个 `.xctest` 包的通过/失败与总数，任一包失败或出现
  `Test Case … failed` 时返回非零；`Tests/BuildWorkflowTests` 加解析测试；CONTRIBUTING 改为引用该命令。
- 验收：人为制造一个失败用例时命令返回非零并指出包名。

### A2 内置名称翻译补齐剩余界面（小）

- 依据：任务 3 只覆盖面板、检查器和标题栏。`BulkAssignmentView.swift:116–125`（批量分配的目标标题）和
  `OutputSettingsView.swift:38,93,131`（输出设置的参数列表）仍直接显示 `definition.name`，英文界面下是中文。
  另有两条提示文案 `ConsoleViewModel.swift:625,796` 直接内插保存的名称。
- 做法：这些显示点改用 `BuiltInNamePresentation.displayName`；不改存储值。
- 验收：英文界面下这三处不再出现内置中文名；现有测试不改。

### A3 对齐与恢复的备份清理（小）

- 依据：`ConsoleViewModel.saveBackup`（`ConsoleViewModel.swift:1019`）在每次打开对齐窗口读取预设后都写一个
  `Backups/temporary-preset-<时间戳>.syx`，即使用户只看预览不写入；没有任何清理。每个约 15 KB。
- 做法：内容相同的备份不重复写（按内容哈希命名或先比对最近一份）；只保留恢复点引用的那一份加最近 N 份。
  不删除不是本功能写的文件。
- 验收：连续打开预览三次只多出一份备份；恢复点引用的文件永不被清理；测试覆盖。

### A4 对齐/连接窗口的可访问性标识与自动化验收（中）

- 依据：`PresetAlignmentSheet.swift` 与 `HardwareConnectionSheet.swift` 没有任何 `accessibilityIdentifier`，
  `tools/verify_*_ui.py` 的原生验收脚本无法稳定定位这两个流程；`docs/UI_ACCEPTANCE.md` 也没有覆盖它们。
- 做法：给两个窗口的按钮、选项和进度加稳定标识；用隔离的假设备（已有 `PresetDevice`/`StartupMIDI` 测试替身的思路）
  写一个 `tools/verify_connection_ui.py`，覆盖：弹窗出现、拒绝、读取连接、对齐预览不写入、写入、恢复。
- 验收：脚本在无设备的隔离实例中通过；`docs/UI_ACCEPTANCE.md` 增加一行。运行需要辅助功能权限，脚本本身可先写好。

### A5 README 与截图（中，需要屏幕录制权限）

- 依据：`docs/images/*.png` 是 2026-11-11 的旧面板，没有显示屏、右侧设备列、设备菜单。
- 做法：用 `tools/capture_readme_screenshots.py` 重新截图并更新 README 的功能描述（连接确认、对齐预设、显示屏）。
- 阻塞：本机终端没有屏幕录制与辅助功能权限。需要用户授权或自己运行脚本。

### A6 显示屏细节（小）

- 依据：`BCRDisplayModel.holdSeconds = 0.8` 是估计值（用户反馈“真机更快”，未测量）；跑马灯图案按用户口述
  “|____| 逆时针，上方合上口”实现，未逐帧核对。
- 做法：把保持时间与跑马灯帧序做成可在一处调整的常量并写明来源；等设备可用时在 B 组测量。现在不改数值。

### A7 文档收尾（小）

- `UI_POLISH.md` 的任务书与执行记录已完成使命：把仍有效的内容（远端设备现状、未做的 12/13）并入本文件与
  `HARDWARE_CONNECT_TEST.md`，然后删除 `UI_POLISH.md`。
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

`LEDRingMode` 的 `spread`、`qual`、`cut`、`damp` 仍返回未知（`LEDRingMode.swift:40`），`bar/off` 未核对。
做法与 2026-11-12 的 bar/pan 校准相同：临时把一个旋钮设为该模式，发 3 组各 8 个值，用户读灯。
只有在打算让对齐功能使用这些模式时才需要做。

## C. 远端设备

### C1 ethanmacair 的 USB 修复驱动（需要用户在该机桌面）

- 现状：override 候选已编译，工程已生成；dext 签署报 `errSecInternalComponent`。
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

## 建议的执行顺序

1. 现在：A1、A2、A3（各自独立，都小）。
2. 随后：A4（脚本）、A7（文档收尾）；A5 等权限。
3. 用户回到 ethanmacair 时：C1，然后立刻做 B1–B4（约 40 分钟，需要用户在设备旁）。
4. B 组结果出来后：按结果修正，再请用户裁定 D1–D4。
5. C2 在 C1 通过并确认有持续远程开发需求后再开工。

## 给执行窗口的提示词（A1–A3）

```text
你在 /Users/ethan/Documents/BCR2000Dev（main 分支）工作。先读 AGENTS.md、CONTRIBUTING.md，再读根目录 PLAN.md，
按顺序实现 A1、A2、A3。每项的依据、做法和验收写在 PLAN.md 里，以它为准。

规则：
1. 只做这三项。不连接设备，不发送任何 MIDI/SysEx。
2. 不改模拟侧文件：Sources/BCRProviderMCPAdapter/SurfaceControl*.swift、docs/SURFACE_*.md、
   configs/package_provider.py、Schemas/、Clients/。冲突热点 SurfaceSession.swift、SurfaceEngine.swift、
   docs/CONTROL_MAP.md 除非必须不要动。
3. 新界面文字走 L10n.text，并在两个 Localizable.strings 成对添加，plutil -lint 检查。
4. 每项一个本地提交（Conventional Commits）。提交前：git fetch；远端有新提交则 git rebase origin/main
   （不 merge、不 force），锁文件变了就运行 python3 configs/surface_plugins_dependency.py update；
   python3 configs/format_repo.py --staged（改了文件就重新 add 再跑）；git diff --check --cached；
   全量测试 swift test --build-path build/swiftpm > /tmp/bcr_test.log 2>&1，然后
   grep -E "Test Suite '.*\\.xctest' (passed|failed)|Test Case .* failed" /tmp/bcr_test.log，
   必须 5 个测试包全部 passed 且没有 failed 用例（A1 完成后改用新的汇总命令）；
   python3 configs/check_domain_boundaries.py；python3 -m unittest discover -s Tests/BuildWorkflowTests。
5. 只提交，不 push，不打标签；push 由审查窗口 review 后执行。
6. 每完成一项，在 PLAN.md 末尾的“执行记录”追加：条目号、提交号、改动文件、测试总数与失败数、未验证之处、
   与 PLAN 的偏离及原因。如实写。
7. PLAN 没覆盖的取舍选改动最小的做法并记录；涉及改用户数据、改既有测试断言、改公开合同的，停下记录。
```

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
