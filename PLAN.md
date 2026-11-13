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

## E. 下一轮不需要设备的工作（2026-11-12 review 后新增）

每项都有代码或实测依据。E1–E4 是 review 或当天实机会话留下的实际缺口，建议优先；E5–E8 是改进（E9 已取消）。

### E1 当天实机结论写入硬件验证记录（小，纯文档）

- 依据：2026-11-12 的实机结果散落在提交说明和 `docs/CONTROL_MAP.md`，`docs/HARDWARE_VALIDATION.md` 里搜不到
  “对齐”“P- 1”“跑马灯”“15.4”等任何一条。AGENTS 要求结论写入实机记录。
- 要写入的事实（都来自当天用户在设备旁的确认或只读测量，出处见括号内提交）：
  - 对齐设备预设写入、回读、按键按住/松开、PRESET 锁定、恢复原预设均通过（`8197562`、`c9f4008`）；
  - bar/pan 灯环 24 个值逐灯一致（`8a7fd35`）；
  - 显示屏：空闲显示 `P- 1`；P1 PUSH（`.showvalue off`）按下时设备显示不变；数值保持时间比 1.5 秒短，未测量；
    预设全文传输期间跑马灯逆时针（`da906f5`、`8a02de9`）；
  - 协议耗时：33 条预设名称 0.93 秒；临时预设全文 554 行 15.4 秒；8 号预设 426 行 11.8 秒（`ff951e8`）；
  - 本机 1 号与 8 号预设同名“Reason Redrum 1”，内容不同；临时预设与 1 号一致；
  - ethanmacair：无修复驱动，只读身份查询无回复，OUT 包长 4（本文件 C1）。
- 验收：`docs/HARDWARE_VALIDATION.md` 新增一节，每条注明“用户目视确认”或“只读测量”，不把假设备结果写进去。

### E2 单个按键启用功能的入口（中）

- 依据：对齐后新增的按键身份是“仅显示按压”。检查器对这类按键只显示
  “此硬件按键仅显示按压；重新学习后才启用所分配的功能”（`ControlInspectorView.swift:74`）。但这些身份来自设备
  预设回读、已经正确，要求用户重新学习没有意义；唯一的批量入口是对齐窗口里的全局勾选项。
- 做法：检查器在该提示旁加“启用此按键的功能”按钮，只把这一个按键的 `visualizationOnly` 去掉（不写设备、
  不改 MIDI 身份），带确认；反向“改回仅显示”同样提供。经 `SurfaceSession` 的映射安装入口保存。
- 验收：单元测试覆盖启用后该按键输入执行分配功能、其他仅显示按键不受影响、身份不变；不发送任何 MIDI。

### E3 测试命令的文档一致性（小）

- 依据：A1 之后 `CONTRIBUTING.md` 与 CI（`ci.yml:23`、`release.yml:44`）都用
  `python3 configs/macos_workflow.py test`，但 `AGENTS.md:59` 的 “Focused checks” 仍列裸的
  `swift test --build-path build/swiftpm`，没有说明它不汇总各测试包。
- 做法：AGENTS 的该行加注“单独运行时须检查全部测试包，或改用上面的 workflow test”。只改这一处。

### E4 对齐窗口的可读性（小到中）

- 依据：修改清单是固定 180 高的滚动区（`PresetAlignmentSheet.swift:139`），本机一次 27 项、假设备 61 项，
  同类条目（如 32 个“新增按键”）逐行平铺；README 截图里只能看到前 11 行。
- 做法：按类型分组并显示每组数量，组内可展开；顶部一行汇总“新增 N、改址 N、灯环 N、按键行为 N、锁定”。
  不改生成逻辑与写入内容。
- 验收：`verify_connection_ui.py` 仍通过（选择器按标识，不按行文字）；新增的分组标题有本地化。

### E5 备份历史可见（小）

- 依据：`PresetBackupStore` 保留最近 5 份加恢复点，但界面上只有对齐窗口底部一行文件名，没有“在访达中显示”，
  用户无法知道有哪些备份、能否手动取回（`PresetBackupStore` 只被 `ConsoleViewModel.swift:1026` 一处调用）。
- 做法：设备菜单加“在访达中显示备份…”；对齐窗口的备份文件名可点击定位。只读，不提供从任意备份写回设备
  （那是写设备操作，属于 D 组决定）。

### E6 预设锁定后把设备键用起来（中，需要用户先决定，见 D5）

- 依据：手册 §13.5/§13.6：`.lock on` 时 STORE/LEARN/EDIT/EXIT 变为按键 53–56，PRESET ◀▶ 变为按键 63–64，
  可像普通按键一样分配 MIDI。现在对齐只加锁、不给它们分配身份，界面上显示为带锁的禁用键，6 个实体键闲置。
- 做法（若 D5 同意）：`BCRLayout` 增加这 6 个控件，对齐时分配未占用的 CC，面板上变为可分配的普通按键。
  这会改 `BCRControlID` 的范围和硬件映射版本，属于较大的领域改动，需要完整的迁移测试。

### E7 连接确认窗口的默认项（小）

- 依据：`HardwareConnectionSheet.swift` 只有“初始化并连接”带突出样式（`:21`），而该选项只在存在启动设置文件
  时出现；常见的两选项场景里没有默认按钮，回车无效，只有 Esc 对应“暂不连接”（`:51`）。
- 做法：把不写设备的“按硬件现状连接”设为默认按钮（回车），并在说明里标注“不改动设备”。写入类选项不设默认。

### E8 假设备夹具与测试替身去重（小）

- 依据：`IntegrationMIDIFixture.swift` 与测试里的 `PresetDevice`、`DisplayDevice`、`StartupMIDI`、`ConfirmationMIDI`
  各自手写同一套 56 旋钮预设和 BCL 帧编码（`[0xF0, 0, 0x20, 0x32, …]` 在测试目录里重复出现多次）。
- 做法：在测试支持代码里提供一个 BCL 帧编码辅助函数和预设构造器，各测试复用。只动测试与 Debug 夹具。

### E9 远程桥接的可行性预研（已取消）

2026-11-13 用户裁定：远程方案只是为了开发时方便连上远端设备，不是远程控制，不存在“值不值得做”的问题，
因此不做立项前的可行性预研。延迟与超时在实现 C2 时实测并处理。见 C2。

## F. 第三轮不需要设备的工作（2026-11-13）

E1–E5、E7 已完成并通过 review。本轮接着做遗留和离屏相关的缺口。F1–F3 可立即执行。

### F1（已完成） 测试替身去重（即 E8，上一轮未做）

- 依据：`grep -rln "0xF0, 0, 0x20, 0x32" Tests` 有 9 个文件各自手写 BCL 帧头；`IntegrationMIDIFixture.swift` 与测试里的
  `PresetDevice`、`DisplayDevice`、`StartupMIDI`、`ConfirmationMIDI`、`ButtonFunctionMIDI` 等重复同一套 56 旋钮预设和假设备。
- 做法：在测试支持代码里提供一个 BCL 帧编码函数和一个预设行构造器，各测试复用；假设备替身能合并的合并。
  SwiftPM 的测试目标之间不能直接共享源码：先看 `Package.swift`，选改动最小的方式（新增一个仅测试依赖的支持目标，
  或在各测试目标内各放一份同名辅助文件），并在执行记录里写明选择与理由。Debug 夹具 `IntegrationMIDIFixture` 在 App 目标内，
  只复用它能访问到的公共函数，不为去重把测试代码搬进产品目标。
- 验收：不改任何测试断言；测试总数不减少；手写帧头的文件数明显下降并在记录里给出前后数字。

### F2（已完成模式分级，见限制） 其余原生验收脚本的离屏运行（中）

- 依据：2026-11-13 只验证了 `verify_connection_ui.py` 可离屏。其余 7 个脚本默认仍在前台，会弹窗并抢焦点：
  `verify_builtin_names_ui.py`、`verify_configuration_ui.py`、`verify_endpoint_ui.py`、`verify_functions_ui.py`、
  `verify_output_ui.py`、`verify_precision_ui.py`、`verify_review_fixes_ui.py`。
  已知障碍（`grep -nE "keystroke|key code|screencapture" tools/verify_*.py`）：
  - 区域截图 `screencapture -x -R80,80,1200,760`（endpoint、precision、review_fixes）：离屏窗口不在该区域，会截到别的窗口；
  - 键盘事件 `key code` / `keystroke`（configuration、output、precision）：系统键盘事件发给前台应用，离屏时会打到用户正在用的应用；
  - 系统打开/保存面板（configuration）：面板是否能在离屏下由辅助功能驱动，未知。
- 做法，逐个脚本处理并逐个记录结果：
  1. 区域截图改为按窗口号截图（`tools/native_ui.py` 的 `NativeUI.capture` 已有按本进程窗口号截图的实现）。
     离屏窗口是透明的，按窗口号截图是否仍得到内容需要实测；得不到时改用 App 自己的渲染输出
     （`--render-ui` 与 `BCR_UI_SNAPSHOT_DIRECTORY` 已存在，见 `BCRAgentConsoleApp.swift`），或保留该脚本为前台并写明原因。
  2. 键盘事件改为辅助功能动作（`tools/native_ui.swift` 的 AXPress / 设置值）。**离屏运行时绝不向系统发送键盘事件。**
     改不了的步骤，该脚本保持前台。
  3. 每个脚本离屏跑通后，用采样确认运行期间前台应用不变、没有可见窗口，再把它列入可离屏清单。
- 验收：`docs/UI_ACCEPTANCE.md` 给出一张表：每个脚本“可离屏 / 必须前台（原因）”。可离屏的脚本在中文下离屏通过；
  必须前台的脚本行为不变。`tools/mcp_integration.py` 带 `--script` 时的默认值不要改成离屏，除非全部脚本都可离屏。
- 不做：不为离屏去改产品界面的行为；不删除任何现有验收断言。

### F3（已完成，测试专用呈现限制见执行记录） 离屏模式的收尾（小）

- 依据（均在 `Sources/BCRAgentConsole/OffscreenPresentation.swift` 与 2026-11-13 的实测）：
  - 离屏状态靠 50 ms 轮询加四个通知维持，轮询在测试进程整个生命周期里空转；
  - 实测中透明窗口的坐标并不总在屏幕外（SwiftUI 会把窗口放回屏幕范围），目前不可见是靠 `alphaValue = 0`，
    “停在所有屏幕之外”的注释与实际不完全一致；
  - `mcp_integration.py` 的 `--offscreen` / `--foreground` 没有测试；`OffscreenPresentationTests` 只测了单个窗口。
- 做法：注释与文档按实测改准确（不可见的保证来自透明与不响应鼠标，屏幕外只是尽力而为）；能用通知覆盖的就去掉轮询，
  去不掉则保留并说明原因；给 `mcp_integration.py` 的参数解析加单元测试（离屏默认值随 `--script` 变化、两个开关互斥）。
- 验收：现有离屏 smoke 与离屏连接验收仍通过；采样确认无可见窗口、前台应用不变。

## B. 需要设备（设备可写之后）

前置：先完成 C1（远端驱动）或把设备插回本机。顺序按依赖排列。

### B1 连接流程实测（HARDWARE_CONNECT_TEST.md A–E，本轮现场通过）

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

> 2026-11-13 夜已解决，结果见 G0；以下为当时的阻塞记录，保留备查。

- 设备自 2026-11-12 起插在 ethanmacair（SSH 可达，登录用户 henrykang，仓库 `~/Documents/BCR2000Dev`）。
  系统识别到 USB 与 MIDI 端口，但只读身份查询无回复；尚未安装 BCRDescriptorProbe 描述覆盖驱动，OUT 包长仍为 4。
- 已只读采集 USB 描述到该机忽略目录 `build/original-usb-report.json`，编译 override 候选并生成
  `build/driverkit-probe/xcode-override` 工程，签署团队沿用该机上次 control 构建。
- 阻塞：dext 签署报 `errSecInternalComponent`，SSH 会话和该机桌面终端均失败；宿主 App 尚未生成，
  没有安装或激活任何扩展。驱动可用前，远程方案（C2）只能先做“只听不发”。
- 排查顺序（都在该机桌面执行）：
  1. `security find-identity -v -p codesigning` 确认开发证书带私钥；
  2. 用任意小文件试签：`codesign -s "<证书 SHA-1>" -f /tmp/test`，若同样报错，说明是钥匙串对 codesign 的私钥访问
     授权问题：在“钥匙串访问”里对该私钥允许 codesign，或 `security set-key-partition-list`（需要登录密码，由用户执行）；
  3. 若试签成功而 xcodebuild 失败，在 Xcode 图形界面打开 `build/driverkit-probe/xcode-override/` 的工程构建一次，
     让它处理描述文件（该机可能未注册在开发者账号的设备列表）。
- 之后按 `docs/DRIVERKIT_USB_PROOF.md` 的复核顺序：安装宿主、系统设置里允许、重新枚举、只读身份查询有回复。

### C2 远程开发方案（确定要做，中到大）

用途（用户 2026-11-13 明确）：设备插在另一台 Mac 上时，本机开发仍能方便地连上它。这是开发便利工具，不是远程控制功能，
不需要先论证是否值得。

- 做法：参照 `XTouchCompactDev` 的 `tools/remote_hardware.py` + `XTouchRemoteMIDI`（说明见其 `docs/REMOTE_HARDWARE.md`）：
  远端桥接进程经 SSH 标准输入输出转发原始 MIDI，本机生成名字含“BCR2000”的虚拟端口，App 像对待 USB 设备一样自动选中；
  不开端口，认证靠 SSH。带部署、状态查询、只听模式和断线重连。桥接两端都不解析、过滤或生成 MIDI。
- 分两步：
  1. **只听不发**，不依赖 C1，现在就能做：远端那台 Mac 已能收到设备的旋钮和按键输入。本机 App 可据此验证输入、
     按压显示和显示屏逻辑。
  2. **双向**，依赖 C1（远端 USB 修复驱动）：灯环回写、读写预设、对齐。
- 实现中要实测并处理的 BCR 特有问题（不是立项门槛）：长 SysEx 经 SSH 与 Tailscale（XTouch 实测约 110–125 ms）后，
  读预设（554 帧，本地 15.4 秒）与逐行确认的写入（每行等 ACK，现为 2 秒超时）会变慢多少；超时不够就按实测调整，
  或让超时随链路类型变化。
- 边界：只用于开发。远端得到的结果只算开发数据，不能替代 USB 直连的 R1 验收；界面上要标明端口来自远端。

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

### D5 锁定后是否启用 6 个设备键（对应 E6）

锁定后 STORE/LEARN/EDIT/EXIT 与 PRESET ◀▶ 可作为 6 个额外的可分配按键。代价：控件总数从 108 变为 114，
硬件映射需要升级版本；用户在设备上临时失去换预设和进入编程模式的能力（恢复原预设即解除，现状已如此）。

### D6 Agent 按键灯闪烁是否默认开启

现在默认关闭，因为没测过设备按键灯对不同数值的反应（B3）。B3 之后决定；若不想等，可先在本机设备上
口头确认“灯只有亮灭两态”，然后直接改默认。

### D7 同名预设的处理

本机 1 号与 8 号预设同名，软件靠读两份全文（各 12–15 秒）区分，结果有缓存。选项：保持现状；
或由用户在设备上给 8 号改名，之后只靠名称即可（约 1 秒）。这是设备上的操作，软件不会替用户改。

## G. 第四轮：跑马灯对齐、端口与设置收尾（2026-11-13 夜）

本组由当晚的工作窗口整理，交给新窗口继续。先读“G0 已完成”，再按“G 组执行顺序”推进。

### G0 当晚已完成（作为新窗口的起点）

- **C1 已解决**：当前工作机就是 ethanmacair。签名这次正常（两个开发证书试签均成功），已重新构建 override 驱动、
  安装宿主到 `/Applications/BCRDriverKitProbe.app`、用户在系统设置授权、软件重新枚举。
  结果：扩展 `activated enabled`，设备节点有 `override-v1` 标记，OUT 包长 4 → 8，只读身份查询返回 `BCR2000 1.10`、输入丢弃 0。
  开发描述文件到期日 2027-11-11。尚未做写入/灯环目视验收，不等同于 `DRIVERKIT_USB_PROOF.md` 的完整验收顺序。
- **MCP 端口工具** `269c0c4`：`list_midi_endpoints`、`set_midi_endpoints`（见 `docs/MCP.md`）。单元测试覆盖，**真机尚未调用**。
- **设置窗口合并** `88ba0ab`：输出/MCP/MIDI 端口并入统一设置窗口（8 页，固定 880 × 720），顶栏胶囊直达对应页。
  端点、内置名称（英文）、语言三个离屏原生验收通过；`verify_output_ui.py` 必须前台，改后未运行。
- **应用按钮**：反馈调度、MCP、输出、设备四页的“应用”在没有未应用修改时禁用；端口设置读取失败需修复时仍可应用。
- 本机终端已获辅助功能权限（2026-11-13 用户开启），离屏原生验收可直接运行。

### G1 跑马灯行为摸清（需要设备，需要用户目视）

- 用户观察到至少四种：顺时针约 1 圈/秒、顺时针约 3 圈/秒、逆时针约 3 圈/秒、逆时针 5 圈/秒以上。
  用户表示速度不必完全对齐，但希望大致摸清规律。
- 当晚只读计时（只发请求 SysEx，不保存内容）：

  | 操作 | 行数 | 跨度 | 速率 |
  |---|---|---|---|
  | 读临时预设全文（0x40 0x7F） | 554 | 15.35 s | 36.0 行/秒 |
  | 读 1 号存储预设全文（0x40 0x00） | 554 | 15.39 s | 35.9 行/秒 |
  | 读全部预设名称（0x42 0x7E） | 32 | 0.86 s | 36.1 行/秒 |

- **假说（未目视证实）**：跑马灯不是按时间转，而是每传一行 BCL 走一步、12 步一圈。依据仅是 36 行/秒 = 12 × 3，
  与“约 3 圈/秒”吻合。写入是逐行等设备确认（`CoreMIDIService.swift` 的 `acknowledged`），速率由设备处理每行的快慢决定，
  因此同一次写入内可能时快时慢，可解释 1 圈/秒与 5 圈/秒以上同属写入。
- **假说解释不了的**：顺、逆时针各有一个约 3 圈/秒；顺时针约 1 圈/秒出现在什么操作。不要把假说写成结论。
- 步骤：
  1. 读取类逐项观察：读名称、读临时预设、读存储预设、快照请求（0x43，确认是否有动画）、身份查询（应无动画）。
     每项间隔数秒，用户报方向与大致圈速。计时脚本当晚放在会话临时目录，未入库；需要时按上表请求码重写，
     放 `tools/`（只读，输出只含行数/时间，不落盘内容）。
  2. 写入类：只走 App 正常流程（对齐预设、恢复原预设、启动设置 `configureStartup`）。用户报方向与速度是否中途变化。
  3. 为写入取数据：在 `acknowledged` 里记录每行确认的时间戳（仅 Debug 或诊断开关，写到忽略的私有目录，只记序号/时间/行首关键字，
     不记预设内容），得到“行类型 → 确认耗时”分布，与目视的快慢段对照。
  4. 验证“每行一步、12 步一圈”：需要一次可控慢速传输。读取速率由设备决定，无法放慢；写入可在行间加延时（例如 2 行/秒），
     让用户数每行走几步。**这需要新增一个仅调试用的行间延时参数，属于写设备路径的改动，先征得用户同意**；
     内容用刚读回的同一份临时预设原样写回，不改变设备状态。
  5. 结论分场景写入 `docs/HARDWARE_VALIDATION.md`（读取/写入/回读/名称/快照各一行），区分“目视”“计时”“推断”。
- 验收：五类操作各有方向与速率记录；假说被证实或被推翻，并注明证据类型。

### G2 软件跑马灯改为按传输进度驱动（依赖 G1 结论）

- 依据：现为固定时间驱动，读 4 圈/秒、写 1 圈/秒（`BCRDisplayModel.swift` 的 `Calibration`，
  视图 `SevenSegmentLEDDisplay.swift` 用 `TimelineView.periodic`）。这两个数是视觉调节值，与真机 36 行/秒 ≈ 3 圈/秒不符。
- 若 G1 证实“每行一步”：
  1. `BCRDisplayModel` 增加按步推进的状态（每收到/确认一行推进一步），`busyFrame` 由步数而非时间计算；方向仍按操作类型。
  2. 读取路径需要逐行进度回调：`sendPresetFrames` 已有 `progress`，`readPreset`/`readPresetNames` 目前没有，需补。
  3. 视图改为随模型步数刷新；进度高于显示刷新率时允许跳帧，但方向不得混叠（现有测试曾因 12 Hz 采样混叠改过采样率）。
  4. 没有进度信号的传输保留时间驱动，并以 36 行/秒（3 圈/秒）为默认。
- 若 G1 推翻假说：只把 `Calibration` 按各场景实测值修正，并更新注释里的来源说明。
- 需同步修改的测试：`LEDDisplayTests.swift` 中写死 4 圈/秒、帧序与写入反向的断言；`SevenSegmentDisplayTests.swift` 的 12 帧段码。
  按 AGENTS 约定，新状态转移要有聚焦单元测试。
- 不变：`busyMasks` 的 12 段外圈图案在逐帧核对前不改；数值保持时间 0.8 秒仍属 B4。

### G3 自动端口策略（需要用户决定）

- 依据：自动模式只接受名字同时含 `BCR2000` 和 `Port 1` 的端点（`MIDIEndpointSelection.swift:49`）。
  本机 CoreMIDI 只列出一个实体、一进一出，端点名就是 `BCR2000`，自动模式因此报“未找到 BCR2000 Port 1”，只能手动选择。
  当晚读到的 101 字节配置描述只声明一个内嵌输入口和一个内嵌输出口；而 `docs/HARDWARE_VALIDATION.md` 记录另一台 Mac
  枚举为输入 Port 1/2、输出 Port 1/2/3。两台机器为何不同尚未查明（可能与设备 USB 模式 U-1…U-4 或系统缓存的设备描述有关）。
- 选项：
  1. 保持现状：本机一直手动选择（现在可用 `set_midi_endpoints`）。
  2. 自动模式在没有 `Port 1`、且恰好只有一个 `BCR2000` 输入和一个 `BCR2000` 输出时接受它，并在状态里明示所用端点。
     这会改动 AGENTS.md 中“Port 1 优先、不加静默回退”的约定，需同步修改 AGENTS、界面文案与 `MIDIEndpointSelectionTests`。
- 先做的调查（不需决定）：在设备上确认当前 USB 模式；对比两台机器的 `tools/macos_usb_descriptor.swift` 输出与 CoreMIDI 实体数。

### G4 MCP 端口工具的真机验证与补齐（需要设备）

1. 用户重启 App，在设置 → MCP 页启用服务并打开“允许设备源切换、MIDI 端口设置、诊断和 Mock 输入”。
2. `list_midi_endpoints` 应列出 `BCR2000` 输入/输出；`set_midi_endpoints` 选中后 `get_status.hardwareConnection.connected` 为真。
3. 验证拒绝路径：外部输出运行时、控件学习中、预设操作中、ID 不存在时均报错且选择不变。
4. 独立服务（`BCRProviderService`）未接这两个回调，调用会报服务不可用。是否接入、选择存在哪里，需按 D3 的连接策略一并决定。
5. 待解释：当晚只读快照返回 90 条 CC，而 2026-11-13 早些时候记录为 108 条（工具与统计口径可能不同）。先确认口径再判断是否有差异。

### G5 设置窗口收尾（不需要设备）

1. 前台运行并记录：`python3 tools/mcp_integration.py --configuration-write --script tools/verify_output_ui.py`。
   同时复跑 `verify_precision_ui.py`、`verify_configuration_ui.py`（未改动，但主窗口结构变化后应确认）。需要用户让出桌面。
2. 在真实窗口逐页目视：当晚只检查了离屏渲染的中文快照，没有在真实设置窗口里逐页点过，英文界面也未看。
3. 留白：语言、反馈调度、配置库内容很少，在 880 × 720 下大片空白。候选做法：三页合并为“通用”页；或改为左侧边栏布局。
   属于观感取舍，先给用户看截图再定。
4. 应用按钮的反馈：现在只做到“无修改时禁用”。可补“已应用”的短暂确认，以及有未应用修改时的提示；
   切换页面会丢弃未应用的草稿（沿用原 sheet 行为），是否改为保留草稿需用户确认。
5. 交互一致性：MCP 的“启用本机 MCP 服务”和输出的“LED 环显示”是即时生效，其余要点“应用”；Agent 页多数字段即时生效。
   列出各页每个控件的生效方式，统一成一种说明或一种行为。
6. README 的六张截图与文字仍是旧的三个 sheet；用 `tools/capture_readme_screenshots.py` 重拍并改描述（先确认脚本是否依赖旧 sheet）。
7. `docs/UI_ACCEPTANCE.md` 能力表里端点一行仍写“自身 sheet 渲染”，按新结构改写。

### G6 驱动与文档收尾（小）

1. 把 G0 的驱动结果写进 `docs/DRIVERKIT_USB_PROOF.md`（第二台机器的可行性记录）与 `HARDWARE_CONNECT_TEST.md`，
   并把本文件 C1 与“现状（2026-11-12）”中“只能收不能发”的描述标为已过时。
2. 按 `DRIVERKIT_USB_PROOF.md` 的验收顺序补完本机的写入验证：已学旋钮五值回读、用户目视灯环变化。
3. 宿主 `BCRDriverKitProbe.app` 可退出，不影响已激活的扩展；回退用宿主的“移除测试扩展”或 `--deactivate`，之后重新枚举。
4. 观察记录：重新枚举前后 Microsoft Edge 都持有该 USB 设备的一个用户客户端，未见影响，原因未查。
5. 本文件开头的检出路径写的是 `/Users/ethan/Documents/BCR2000Dev`，当前实际为 `/Users/henrykang/Documents/BCR2000Dev`，核对后更正。

### G7 借设备在手推进 B 组（需要设备）

设备现在在本机且可写，B2–B6 与 `HARDWARE_CONNECT_TEST.md` 的剩余项可以直接做，顺序不变：
B2 对齐后的按键行为 → B3 Agent 按键灯 → B4 显示屏（数值保持时间 0.8 秒、`on`/`oFF` 时长、计数式按键）→ B6 未校准灯环模式。
B4 的跑马灯部分由 G1/G2 承担。注意本机尚未在新驱动下做过任何写入，先完成 G6 第 2 条。

### G 组执行顺序

1. G4 第 1–2 步（让 App 连上设备，后面都依赖它）。
2. G1 第 1–2 步（纯观察，不改代码），随后第 3 步取写入时序。
3. G6（文档与本机写入验收）。
4. G1 第 4 步与 G3 等用户决定；G2 等 G1 结论。
5. G5 可随时穿插，其中第 1 步需要用户让出桌面。
6. G7 在 G6 第 2 条通过后进行。

### 给新窗口的提示词（G 组）

```text
接手 BCR2000Dev（工作目录 /Users/henrykang/Documents/BCR2000Dev，主机 ethanmacair，设备已插在本机且驱动已装好）。
先读 AGENTS.md、PLAN.md 的 G 组（G0 是起点）、docs/HARDWARE_VALIDATION.md 末尾的跑马灯段落。
只在 main 工作树开发，每个验证过的改动单独提交并推送；不建分支、不打标签。
设备写入只走 App 的正常流程；工具只发只读查询。新增任何写设备路径（包括 G1 第 4 步的调试延时）先问用户。
按“G 组执行顺序”推进：先让 App 通过 set_midi_endpoints 连上名为 BCR2000 的端口，再做跑马灯观察。
需要用户目视的步骤，一次只请用户看一项，说明要看方向和大致圈速；用户的话原样记入硬件验证记录，区分目视、计时、推断。
G3 的自动端口策略、G5 的留白方案和草稿保留属于用户决定，不要自行改默认行为。
每完成一项在 PLAN.md 的执行记录追加提交号、验证结果和未验证项；测试失败或脚本未运行要照实写。
```

## 下一步执行顺序

1. A 组与 E1–E5、E7 已完成并通过 review，已推送。
2. F1–F3 已完成并推送（2026-11-13）；设备接回本机，B1 本轮 A–E 现场路径已完成，后续按 B2–B4 推进。
   C2 的第一步（只听不发）仍是独立待办，未因本机接回而自动完成。
3. E6 等 D5 的决定；D6、D7 可随时由用户口头决定。
4. 本机已可只读访问设备，现可按 B1–B4 推进，结果写入硬件验证记录；ethanmacair 的 C1 签署/驱动问题仍待该机桌面处理。
5. 根据 B 组结果修正软件，再裁定 D1–D4。C1 完成后做 C2 的第二步（双向）。
6. 2026-11-13 夜：C1 已在 ethanmacair 解决（见 G0），设备在该机可双向通讯。后续按 **G 组执行顺序**推进，G 组优先于上面各条。

## 给执行窗口的提示词（F1–F3）

```text
你在 /Users/ethan/Documents/BCR2000Dev（main 分支，SwiftUI/CoreMIDI 的 BCR2000 控制台）工作。
先读 AGENTS.md、CONTRIBUTING.md，再读根目录 PLAN.md 的“F. 第三轮不需要设备的工作”，按顺序实现 F1、F2、F3。
每项的依据、做法和验收写在 PLAN.md 里，以它为准。

规则：
1. 只做 F1–F3。不连接设备，不发送任何真实 MIDI/SysEx；需要设备行为时只用隔离的假设备。
2. 不打扰桌面：这台机器上同时有人在别的应用里工作。
   - 启动 App 的检查一律离屏：python3 configs/macos_workflow.py smoke 本机已默认离屏；
     tools/mcp_integration.py 带 --script 时显式加 --offscreen。
   - 只有在验证“某脚本必须前台”时才允许前台运行，每次运行前在执行记录里写明原因，跑完立即结束。
   - 离屏运行时绝不向系统发送键盘事件（osascript 的 keystroke / key code 会打到用户正在用的应用）。
   - 不要打开访达、系统设置或任何其他应用的窗口。
3. 不改模拟侧文件：Sources/BCRProviderMCPAdapter/SurfaceControl*.swift、docs/SURFACE_*.md、
   configs/package_provider.py、Schemas/、Clients/。冲突热点 SurfaceSession.swift、SurfaceEngine.swift、
   docs/CONTROL_MAP.md 只在条目必须时改动，并在执行记录里说明。
4. 不改任何现有测试断言，不删除验收步骤。F1 是纯重构，测试总数不得减少。
5. 新界面文字走 L10n.text，两个 Localizable.strings 成对添加，plutil -lint 检查。
6. 每项一个本地提交（Conventional Commits）。提交前：
   - git fetch；远端有新提交则 git rebase origin/main（不 merge、不 force）；
     锁文件变了就运行 python3 configs/surface_plugins_dependency.py update。
   - python3 configs/format_repo.py --staged（它改了文件就重新 git add 再跑一次）；git diff --check --cached。
   - python3 configs/macos_workflow.py test（必须显示 5 个模块全部 PASS，并报告总测试数）。
   - python3 configs/check_domain_boundaries.py；python3 -m unittest discover -s Tests/BuildWorkflowTests。
   - 改了 App 或验收脚本的条目：python3 configs/macos_workflow.py build && python3 configs/macos_workflow.py smoke，
     再离屏跑受影响的验收脚本。
7. 提交时不要留下已暂存但未提交的改动；每项做完工作区必须干净。
8. 只提交，不 push，不打标签；push 由审查窗口 review 后执行。
9. 每完成一项，在 PLAN.md 的“执行记录”追加：条目号、提交号、改动文件、测试总数与失败数、
   哪些是离屏跑的、哪些是前台跑的及原因、未验证之处、与 PLAN 的偏离及原因。
   如实写：失败、没做完、只做了一部分的，都要写明，不要写成已完成。
10. PLAN 没覆盖的取舍选改动最小的做法并记录；涉及改用户数据格式、改公开合同、改产品界面行为的，停下记录，不要自行决定。
```

## 上一轮的提示词（E1–E5、E7、E8，已执行，保留备查）

```text
你在 /Users/ethan/Documents/BCR2000Dev（main 分支）工作。先读 AGENTS.md、CONTRIBUTING.md，再读根目录 PLAN.md 的
“E. 下一轮不需要设备的工作”，按顺序实现 E1、E2、E3、E4、E5、E7、E8。每项的依据、做法和验收写在 PLAN.md 里。
E6 与 E9 不在本次范围（E6 等用户决定，E9 后来已取消）。

规则：
1. 只做列出的条目。不连接设备，不发送任何真实 MIDI/SysEx；需要设备行为时只用隔离的假设备。
2. 不改模拟侧文件：Sources/BCRProviderMCPAdapter/SurfaceControl*.swift、docs/SURFACE_*.md、
   configs/package_provider.py、Schemas/、Clients/。冲突热点 SurfaceSession.swift、SurfaceEngine.swift、
   docs/CONTROL_MAP.md 只在条目必须时改动，并在执行记录里说明。
3. E1 只写当天有出处的事实，每条标注“用户目视确认”或“只读测量”，不写假设备结果，不推断未测的内容。
4. E2 会让实体按键执行功能：必须有确认步骤、单元测试，且不能改变其他按键或任何 MIDI 身份。
5. 新界面文字走 L10n.text，两个 Localizable.strings 成对添加，plutil -lint 检查。
6. 每项一个本地提交（Conventional Commits）。提交前：git fetch；远端有新提交则 git rebase origin/main
   （不 merge、不 force），锁文件变了就运行 python3 configs/surface_plugins_dependency.py update；
   python3 configs/format_repo.py --staged（改了文件就重新 add 再跑）；git diff --check --cached；
   python3 configs/macos_workflow.py test（必须显示全部测试包 PASS）；
   python3 configs/check_domain_boundaries.py；python3 -m unittest discover -s Tests/BuildWorkflowTests；
   改了连接/对齐界面的条目再跑中英文 tools/verify_connection_ui.py，并给 tools/mcp_integration.py 加 --offscreen
   （离屏运行，不弹窗、不抢焦点；本机 smoke 已默认离屏）。
7. 只提交，不 push，不打标签；push 由审查窗口 review 后执行。
8. 每完成一项，在 PLAN.md 的“执行记录”追加：条目号、提交号、改动文件、测试总数与失败数、未验证之处、
   与 PLAN 的偏离及原因。如实写，失败或没做的也要写。
9. PLAN 没覆盖的取舍选改动最小的做法并记录；涉及改用户数据格式、改既有测试断言、改公开合同的，停下记录。
```

## 本轮执行约束

- 本轮按用户指令完成 A1–A7；B–D 留待设备及用户决定。不连接实体设备，不发送真实 MIDI/SysEx。
- 始终在 main 验证并逐项本地提交，不建分支/额外检出，不 push、不打标签；审查窗口负责 review 后推送。
- 保留模拟侧实现、Schemas、Clients 及 Provider 合同；CONTROL_MAP 只按 A7 明确范围更新现状说明。
- 新文案成对本地化；不改既有测试断言。测试替身入口变更、失败修正与额外提交在下方如实记录。
- 以 `python3 configs/macos_workflow.py test` 汇总全部包，运行边界、BuildWorkflow、格式和相关原生验收；
  未验证项分别记录。提交号随下一次文档更新补入，末项由收尾记录补齐。

## Review 结论（A1–A7，审查窗口，2026-11-12）

独立复跑，与执行记录一致：`python3 configs/macos_workflow.py test` 5 个测试包 525 项、失败 0；BuildWorkflow 76 项；
域边界、全仓格式、双语 strings lint 通过；Release 配置编译通过（确认 `#if DEBUG` 的假设备不影响发布构建）；
中文 `verify_connection_ui.py` 在我这里重跑通过（case-vx_s5m7h）。逐提交读了全部源码差异，逐张看了六张截图。
全部通过，没有需要修正的缺陷。

- **A1**：通过。用六种日志单独验证了 `summarize_tests`：全部通过为真；前面的包失败而 swift 退出 0、缺包、
  非零退出、没有预期包、输出截断均为假。预期包名取自 `Package.swift` 的 `.testTarget`，清单写法变化时会按
  “没有预期包”失败，方向安全。
- **A2**：通过。补充提交 `153c0a3` 又找出三处同类漏点并加了英文界面的原生验收脚本，超出任务书但在目标范围内。
- **A3**：通过。清理只针对两种命名的普通文件，且哈希命名须与内容一致、旧时间戳命名须能解析为完整预设；
  恢复点引用的文件不删。一处值得知道的行为：用户放进该目录、名字恰好符合旧时间戳格式且内容是合法预设的文件，
  会被当作本功能的备份参与“最近 5 份”清理。概率很低，未改。
- **A4**：通过。假设备入口需要 `--connection-fixture` 与 `--integration-test` 同时出现，整体在 `#if DEBUG` 内，
  数据在隔离目录。`BCR_CONNECTION_FIXTURE` 只是脚本间的约定，App 不读它。
- **A5**：通过。六张截图都只有应用自身窗口，没有其他窗口、路径或账号信息；两张流程图标注为内存假设备。
- **A6**：通过。只是把常量集中并写明来源，数值与帧序未变。
- **A7**：通过。`UI_POLISH.md` 删除前的内容可用 `git show 80a0ef8:UI_POLISH.md` 取回；设备现状、未做的实测、
  签署排查步骤都保留在本文件与 `HARDWARE_CONNECT_TEST.md`。

未验证：没有设备；英文原生验收与 `verify_builtin_names_ui.py` 我没有重跑，用的是执行记录；黑盒 14 组本轮未涉及。

## Review 结论（E1–E5、E7 与离屏测试，审查窗口，2026-11-13）

审查范围是 rebase 到 `ed213e1` 之后的八个提交。独立复跑：`python3 configs/macos_workflow.py test` 五个模块逐个
独立进程共 538 项、失败 0；BuildWorkflow 90 项；域边界、全仓格式、命令校验、双语 strings lint 通过；
离屏 smoke 通过；中英文 `verify_connection_ui.py` 以 `--offscreen` 运行通过。逐提交读了源码差异，看了重拍的截图。
没有发现需要修正的缺陷。

- **E1**（硬件验证记录）：通过。每条标了“用户目视确认”或“只读测量”，没有写入假设备结果，也没有扩大结论。
- **E2**（单个按键启用功能）：通过。确认框针对点击时捕获的绑定，绑定变了、换了设备源或正在学习时拒绝；
  不发 MIDI、不改身份和其他按键，均有测试。执行窗口留在暂存区的取消按钮修正已作为独立提交纳入。
- **E3**（AGENTS 测试命令说明）：通过。
- **E4**（修改清单分组）：通过。分组默认折叠，顶部有各类数量汇总；生成与写入逻辑未动。
- **E5**（在访达中显示备份）：通过。只做文件导航。离屏测试时不打开访达（见下）。
- **E7**（连接确认默认项）：通过。回车对应不写设备的“按硬件现状连接”，写入类选项没有默认快捷键。
  该提交没有对应的执行记录条目，内容以提交说明为准。
- **E8**（测试替身去重）：**未做**，没有对应提交；测试目录里仍有 9 个文件各自手写 BCL 帧头。留待下一轮。
- **离屏测试**（审查窗口实现）：本机 `smoke` 与不带脚本的 `mcp_integration.py` 默认离屏。实测期间无可见窗口、
  前台应用不变。其余 7 个验收脚本未做离屏验证，默认仍在前台。

未验证：没有设备；`verify_builtin_names_ui.py` 与其余 7 个原生验收脚本本轮没有重跑；Swift 6.0 工具链下的编译没有验证
（本机为 6.4.2）。

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

### A7 — `21b8ea4`

- 改动：PLAN、TODO、HARDWARE_CONNECT_TEST、CONTROL_MAP、UI_ACCEPTANCE 同步现状并删除 UI_POLISH。
  远端 USB/签署证据保留在 C1；原 13 的 A–E、G 及 F 剩余项保留在 B 组和连接清单；原 12 由 A5 完成。
- 验证：最终 Swift 五包 525 项、失败 0（PluginHost 11、AgentCore 271、AgentConsole 158、ProviderDomain 26、
  ProviderAdapter 59）；BuildWorkflow 76 项、Python SDK 6 项，失败均 0。边界、全仓格式、命令校验、
  双语 strings lint、最终 App 双语 1200×760 startup smoke、相关本地 Markdown 链接检查全部通过。
- 未验证：B–D 的设备、驱动签署、真实 LED/显示屏计时与初始化连接分支仍按文中标记待做。没有把假设备当作实机证据。
- 执行记录在下一次文档提交补齐上一提交的真实编号，避免自引用提交号；此记录提交只补元数据，不改变实现。

### 最终交接

- A1–A7 完成；A2 和 A4 的补充分别独立提交为 153c0a3、ec225b4，过程与验证见上。
- 本轮全部工作在 main；与远端同步到 6acc14b，锁定依赖 6071354e454bf1c5584e4608aa4ecf022c58238a。
  保留模拟侧所有提交，没有修改 Schemas/Clients/模拟实现，没有 push、tag 或真实 MIDI/SysEx IO。
- 审查入口：逐项提交、两项补充及本执行记录；README 六张图片均为应用自身窗口，四张 Mock、两张内存假设备。
  A2 补充只改变英文内置名称显示，中文截图仍对应最终布局。

### E1 — `de10de8`

- 改动：HARDWARE_VALIDATION 新增 2026-11-12 补充节，逐条标注用户目视确认/只读测量及来源提交。
  覆盖对齐/回读/恢复、24 值灯环、显示与跑马灯、查询耗时、同名预设内容、远端 OUT 包长与无回复。
- 验证：Swift 五包 531 项、失败 0；BuildWorkflow 76 项、失败 0；域边界、格式通过。
- 未验证/偏离：只整理 PLAN E1 指定的既有证据，没有新设备操作，没有假设备结果；未测内容继续列为待验。

### E2 — `7dab00e`

- 改动：检查器增加单键启用/仅显示的确认入口；ConsoleViewModel 核对捕获身份和当前状态，仅修改选中条目的标志，
  委托已有 SurfaceSession.installHardwareMap 保存；新增 HardwareButtonFunctionTests 四项，扩展原生脚本确认/取消验证。
  文案成对翻译；README 与 CONTROL_MAP 的过期“只能重新学习”说明按 E2 必须范围更新，未改领域热点文件。
- 验证：Swift 五包 535 项、失败 0；BuildWorkflow 76 项、失败 0；边界、strings lint、build、双语 smoke 通过。
  中英文原生脚本通过（case-9zqoe0eq、case-vg8wcd56），验证取消零改动、确认只改一项、身份/其他条目/预设写入次数不变。
- 过程：新增测试首轮误用 noteOn 参数标签导致编译失败，修正后完整重跑；原生 AX 偶尔在确认框关闭后丢失回复，
  脚本以精确落盘结果和确认框消失核实动作，不重复点击、不忽略最终状态错误。
- 未验证/偏离：仅隔离假设备，没有真实 MIDI/SysEx；保留安装入口已有的持久化错误提示，不覆盖为成功通知。

### E3 — `d4b636a`

- 实现仅修改 AGENTS.md 的一个命令行注释，提示直接运行 Swift 测试时须核对所有测试包，或使用 workflow test。
  PLAN 的同步改动仅为上项执行记录。
- 验证：Swift 五包 535 项、失败 0；BuildWorkflow 76 项、失败 0；边界、格式、差异检查通过。
- 未验证/偏离：纯文档，无运行行为变化，无额外 AGENTS 改动，无设备操作。

### E4 — `45c606c`

- 改动：PresetAlignmentSheet 按六种类型汇总数量并可分别展开；同一类型保留原明细顺序，生成器与 BCL 内容未改。
  新分组/行标识与双语标题；原生脚本验证展开/收起期间零预设写入，并支持单独输出最小窗口截图。
- 验证：Swift 五包 535 项、失败 0；BuildWorkflow 76 项、失败 0；边界、strings lint、build、双语 smoke 通过。
  中英文完整原生验收通过；逐张查看 1200×760 截图（case-39ll41hp、case-pvswluxk）。
- 过程/偏离：视觉检查发现原有英文灯环选项截断，增加按宽度换行后重跑全量及双语验收；没有业务/写入内容改动。
  README 流程图片待 E7 默认项调整后统一刷新；没有设备操作。

### E5 — `5d243c8`

- 改动：设备菜单“在访达中显示备份…”打开已有 Backups 目录；对齐文件名链接定位对应文件，文件缺失/目录打开失败可见。
  长文件名在固定宽度内截断，help 保留完整路径；仅文件导航，没有新增任意备份恢复入口。
- 验证：Swift 五包 535 项、失败 0；BuildWorkflow 76 项、失败 0；边界、strings lint、build、双语 smoke 通过。
  双语原生脚本实际点击文件和目录入口，校验备份字节、恢复点流程及设备预设写入次数不变；检查最小窗口链接布局。
- 未验证/偏离：没有真实设备；Finder 自身窗口未另做辅助功能树断言，定位使用系统 NSWorkspace API，原生脚本只断言 App 与文件状态。

### F1 — `680ff40`（rebase 前 `3da141c`）

- 改动：新增仅 CoreTests/ConsoleTests 依赖的 BCRTestSupport（BCLFixtures、RecordingMIDIService）；共享帧编码、
  预设行和 56 旋钮映射构造，合并 PressMIDI/ButtonFunctionMIDI/BlinkMIDI/ConfirmationMIDI 的记录型行为，
  保留各自端口名与启动通知差异。Package 产品目标未添加依赖，专用快照/显示/失败替身继续保留。
- 帧头文件统计：Tests 下包含原始帧头的文件由 9 降至 5；剩余为公共构造器、3 个含原始字节断言的 Swift 文件及
  Python 诊断测试。原有 XCTest 断言行无改动，预设数据/测试步骤语义保留。
- 验证：5/5 模块 PASS，共 538 项、失败 0，未低于基线 538；BuildWorkflow 90 项、失败 0；
  域边界、命令、格式和差异检查通过。未启动验收 App，未前台运行，未发送真实 MIDI/SysEx。
- 选择/偏离：采用仅测试依赖的新支持目标，避免把测试代码引入产品。Debug 夹具没有可直接复用的公共 BCL 编码入口，
  故不为去重新增产品 API 或搬入测试支持代码；保留其独立构造。F1 未改 App/验收脚本，无需运行其 UI 场景。
- 提交号在下一项文档更新补入，避免提交引用自身编号；每项提交后保持工作区干净。

### F2 执行范围记录（验证前）

- configuration 脚本保持必须前台：ConsoleViewModel.presentConfigurationPanel 直接 NSApp.activate / makeKeyAndOrderFront，
  并依赖系统文件面板与 Go to Folder。改变该行为超出本轮范围；本机有人工作，因此不进行前台验证。
  保留所有原验收步骤和断言，离屏请求在进入这些步骤前明确拒绝。
- 其余脚本逐个离屏验证。原生内置名称脚本的原断言专用于英文，保留英文验收；其余使用中文。
  当前轮不运行任何前台脚本、不发送系统键盘事件，不打开访达/设置等其他应用。
- 截图优先采用测试 App 内 cacheDisplay 渲染当前主视图/当前 sheet，Debug 通知仅在显式隔离模式注册，
  不新增产品 UI、网络工具或公开合同；不会读取其他应用的像素。新适配器只产生隔离目录里的 PNG。

- precision 离屏试验失败于原有步长断言：AXSetValue + AXConfirm 在不聚焦时未更新 0.25；前台提交步骤不删，
  恢复原 Tab 提交动作并加离屏提前拒绝。为不打扰桌面，本轮不进行前台验证，保留“必须前台”分类。

- output 离屏试验未通过原连接状态断言；落盘端口仍为 9000，说明 AXConfirm 未提交动态端口。恢复原前台 Tab 步骤，
  离屏提前拒绝；未改启动/限速/停机/重连任何验收断言，未运行前台路径。
- review_fixes 的业务步骤通过，但首次桌面审计记录一次可见窗口候选，尚未判离屏通过。
  审计补充真实屏幕边界相交检查及窗口元数据，并对目标测试进程增加立即终止保护；不对其他应用执行操作。

### F2 — `03b1c23`（rebase 前 `3881e1a`）

- 逐项结果：builtin_names 英文离屏通过（case-d4iwre6x；固有英文断言不改，中文不适用）；endpoint 中文通过
  （case-op39rfl5）；functions 中文通过（case-qte27ce8）；review_fixes 中文通过（case-p07c1cav）。
  既有 connection 中文离屏回归通过（case-lib3f1zg），取消/读取改用定向 AX 动作，前台快捷键分支保留。
- configuration 必须前台：产品面板主动激活 App；output/precision 离屏 AX 数值提交未通过原断言，端口仍为 9000、
  步长未更新。三者恢复/保留原前台步骤，新增离屏提前拒绝；拒绝路径均离屏验证，未发送系统按键、未进入面板流程。
  本轮全部运行都离屏，没有前台运行、没有打开访达或其他应用窗口。
- 安全与截图：NativeUI 拦截离屏系统按键并过滤激活/移动/聚焦请求；Debug 隔离进程自身渲染当前 view/sheet。
  WindowServer 端点试验找不到可截取主窗口，故用自身渲染。有限桌面采样只看本测试 PID，发现抢焦点/可见窗口立即终止测试。
  上述成功运行均前台 PID 稳定、targetWasFront=false、visibleSamples=0；原生图已检查，无其他应用像素。
- 验证：5/5 模块 PASS，538 项、失败 0；BuildWorkflow 94 项、失败 0（新增 4 项离屏安全测试）；边界、build、
  离屏双语 smoke、格式通过。现有 Python assert 的 AST 逐项比对未变，未删除任一验收步骤。
- 失败与修正：首次 Debug 渲染通知捕获 Notification 不符合 Swift 6 隔离，改传 String 值后通过；同步了过期端点 help、
  USER 嵌套按钮和精度 radio-group 选择器。review_fixes 首次粗粒度审计有一次可见候选，未判通过；补真实屏幕边界判据与
  立即终止保护后复跑通过。不把失败日志当通过。一次失败函数试验期间用户前台 PID 有变化，但测试 App 从未前台。
- 与字面验收偏离：内置名称脚本保留既有英文断言，仅以英文离屏验证；没有伪造中文通过。三项必须前台的完整原路径
  本轮未跑，理由与原步骤保留在 UI_ACCEPTANCE 表中。未改变产品 UI 行为、公开合同或用户数据格式。

### F3 排查过程（中间结论，最终结果见后）

- 通知维护版本的离屏 smoke 采样通过，但中文连接脚本一次在功能确认框路径发生测试 App 激活；该次判失败，未放行。
- 监测器原 SIGTERM 没能立即结束 Cocoa 进程，改为仅针对明确目标 PID 的 SIGKILL，不影响其他进程。
- accessory 仍允许 App 激活；接下来只在显式离屏测试模式尝试 prohibited 策略，普通启动维持 regular。
  先离屏 smoke 验证，确认框路径不再按原方式继续试跑；不改产品界面、设备协议或用户数据。

- prohibited 实验的 smoke 未通过：窗口不能成为可验证的主窗口；该次采样无激活/可见窗口，已恢复 accessory。
- 按 F3 允许的保守分支保留原有 50 ms 维护任务：通知-only 连接采样失败，禁止激活方案破坏 smoke，
  暂无不改产品 UI/验收断言的可靠替代。文档明确未完成“移除空转”，不伪称已去掉；继续严格离屏回归。

### F3 约束冲突与停止记录

- prohibited 策略在保留布局/可见性校验、改用内容识别后通过 smoke，采样无激活/可见窗口；
  但原生连接确认框未进入 AX 树，原有“弹窗出现”断言失败。该策略及窗口选择实验已全部回退。
- 恢复原 accessory/50 ms 路径后，严格采样仍在 script 阶段捕获测试 App 激活；不是仅退出阶段的误判。
  已终止测试实例，没有以失败结果冒充通过，也未发送系统键盘事件。
- 真实原生确认流程与强禁止激活无法在当前实现中同时验证。修改产品确认呈现超出本轮授权，按规则 10 停止该路径。
  完整连接脚本严格离屏提前拒绝，原前台步骤/所有状态断言保留；本轮不运行前台。
- 此阶段连接离屏验收未完成，曾保守保留既有 50 ms 维护；最终结果见后，不能据本阶段判断轮询必要性。
  需要用户决定是否允许测试专用非激活确认呈现，或正式将完整连接验收保留前台。
- 一次格式化失败后，命令链的独立后续命令仍启动了旧构建验收，发现后已立即结束本次所有目标进程，改用失败即停；
  该次没有完整审计结果，不计通过。没有对其他应用或进程执行终止/激活动作。

### F3 — `c316180`（部分完成：完整连接严格离屏验收未通过）

- 已实现：准确说明透明/鼠标穿透与尽力放置；通知维护覆盖多窗口，移除 App 内 50 ms 常驻任务；
  补充参数默认/互斥/传参/非法端口、非交互退出与前台退出兼容测试，新增两项多窗口/通知停止测试。
  离屏实例直接回收以避免 Cocoa 退出交互；确认框驱动等待稳定状态，所有原 assert 不改。
- 最终验证：5/5 模块 PASS，540 项、失败 0（原 538 + 两个窗口测试）；BuildWorkflow 110 项、失败 0
  （含合入远端新增测试）；域边界、build、格式、命令检查通过。SDK 6 项此前通过。
- 无轮询实跑：双语 smoke（smoke-nopoll-riz92d3p）及 endpoint 中文 case-7j3f_wkd、functions 中文 case-kfzui9m3、
  review_fixes 中文 case-a3q3wdkc、builtin_names 英文 case-mxat6zvq 均通过，所有样本前台 PID 稳定、
  targetWasFront=false、visibleSamples=0。其他失败或前台有变化的历史运行未混入该结果。
- 未完成：原要求“完整连接离屏验收仍通过”未达成。原生功能确认框在 script 阶段激活测试 App；
  禁止激活实验虽可渲染 smoke，但确认框不可访问。两种呈现实验已回退，不修改产品界面或放宽断言。
  完整连接离屏提前拒绝的安全路径通过，原前台步骤保留；须决定测试专用非激活确认承载或正式保留前台。
- 本轮没有前台验收运行，没有发送系统键盘事件，没有打开访达/系统设置或其他应用窗口；
  异常测试 App 激活已如实记录并终止目标实例，不计通过。未处理 F4，没有真实 MIDI/SysEx。
- 同步：本轮两个既有提交 rebase 到 bfa1151，按锁更新到 c6b3083de6e96a8315aee58c7bf18d97003aa21a；
  保留远端全部提交，未改模拟实现、Schemas/Clients 或公开合同。提交号由后续收尾索引补齐。

### F3 最终合入验证（06952e0 基线）

- 收到远端测试隔离提交后再次 rebase，未改其测试断言或实现；最终 5/5 模块 PASS，541 项、失败 0：
  PluginHost 11、AgentCore 271、AgentConsole 166、ProviderDomain 26、ProviderAdapter 67。
  BuildWorkflow 115 项、失败 0；新增参数/多窗口测试保留。SDK 6 项通过，格式/域边界/命令检查通过。
- 最近一次 App 代码与已通过的无轮询四脚本/smoke 版本一致；该远端提交仅调整测试隔离与测试证据，未改 App。
- F3 仍按“部分完成”交付：连接严格离屏项未通过，绝不以 541 项单测通过替代原生验收。

### F 组提交索引与交接

- F1：680ff40（完成，帧头文件 9→5，538 项原测试未减）；F2：03b1c23（完成模式分级，4 个新增脚本可离屏、3 个保留前台）。
- F3：c316180（部分完成；去空转、准确注释、参数/多窗口测试完成，完整连接严格离屏项未通过）。
- 完整连接脚本已安全提前拒绝离屏，待用户决定测试专用非激活确认承载或正式保留前台；没有自行改产品确认界面。
  名称脚本固有英文断言保留，英文离屏通过，未伪称中文通过；所有必须前台的原流程本轮未跑。
- 最终基线 06952e0，依赖 c6b3083de6e96a8315aee58c7bf18d97003aa21a；全部实现本地提交，未 push/tag。
  未处理范围外桥接任务；未连接真实设备。所有项目提交后工作区干净，收尾记录不改变实现。

### F3 继续执行（2026-11-13）

- 用户要求继续完成全部；保留不打扰桌面、不改产品确认行为/断言的约束。
- 尝试仅在复制的离屏 Debug 集成包指定专用 NSApplication，拦截其显式激活请求；不替换原生确认框或业务动作。
  普通产品包 PrincipalClass 和前台验收保持原样；宿主类型不符时立即拒绝启动。继续严格审计，失败不放行。

- 继续排查：Info.plist 的 PrincipalClass 未替换 SwiftUI 的宿主类型，已删除该实验。仅拦截实际应用类两个公开激活方法后，
  中文连接流程曾通过，但补充 AXFocusedApplication 采样后捕获原生菜单取得焦点，立即终止目标；此失败不计通过。
  初版误用系统级 AXFocusedUIElement，查 SDK 后改为系统级 AXFocusedApplication，读取失败数保留在报告中。
- 最小测试呈现选择：只在离屏测试中用不可成为 key/main 的 nonactivatingPanel 承载原连接/对齐视图及原菜单/确认动作；
  普通产品和前台验收仍走原生控件。所有状态断言、文案、业务入口不变；不新增用户数据格式或公开合同。
  这是对测试呈现的适配，不能用它证明系统原生菜单/确认窗口本身不抢焦点；后者本轮未前台验证。

### F3 续作验收 — `17aca89`（已完成，限制见下）

- 改动文件：`Sources/BCRAgentConsole/OffscreenActivationGuard.swift`、`OffscreenInteractionPanel.swift`、
  `OffscreenPresentation.swift`、`IntegrationWindowCapture.swift`、`ContentView.swift`、`ControlInspectorView.swift`、
  `SurfacePanelView.swift`、`WorkspaceTabsView.swift`、`BulkAssignmentView.swift`；
  `Tests/BCRAgentConsoleTests/OffscreenActivationGuardTests.swift`、`OffscreenInteractionPanelTests.swift`；
  `Tests/BuildWorkflowTests/test_native_offscreen_safety.py`；`tools/desktop_audit.swift`、`native_ui.py`、
  `verify_connection_ui.py`、`verify_builtin_names_ui.py`、`verify_review_fixes_ui.py`；`docs/UI_ACCEPTANCE.md`、本计划与 TODO/ROADMAP。
- 新增 4 项 Swift 测试（两个公开激活入口的局部隔离、非法类拒绝、面板不成为 key/main、普通启动不创建面板），
  新增 2 项 Python 测试（前台 PID 未变但焦点转移仍拒绝、无有效焦点观测拒绝）。原有测试断言未改；三个调整脚本的原 assert AST 对比一致。
- 更严格采样还捕获专业面板菜单、批量参数组菜单取得焦点；立即结束隔离测试实例，失败未计通过。
  只在离屏分支复用非激活菜单载体，仍执行原来的面板启用和参数组选择；前台脚本步骤完整保留。
- 最终离屏运行：中文连接 case-z5dvmm1b（234 样本）、英文连接 case-5nebgu31（233）、
  endpoint 中文 case-65y7ocn0（52）、functions 中文 case-3mylgw9a（73）、
  review_fixes 中文 case-zg8ylycc（61）、builtin_names 英文 case-y77wb9ur（93）；
  双语 smoke 为 build/offscreen-audits/smoke-f3-final-ib6budr9（29 样本）。每次均 foregroundStable=true、
  targetWasFront=false、focusedTargetSamples=0、visibleSamples=0；每份报告有 1 次焦点读取失败，其他读数均为原前台应用。
  有限 50 ms 采样不是连续时刻的保证；报告完整保留失败数，不把无法读取当作已确认无焦点。
- 自身渲染的连接/对齐 PNG 已查看；初版透明背景不便审查，离屏面板补了深色背景和 darkAqua 外观后重新构建、采集、通过完整连接。
  图片在忽略目录 build/ui-validation/f3-final，不读取其他窗口像素、不替换 README 图片。
- 所有真实 App 启动均离屏，没有有意前台运行，也没有系统键盘事件、访达、设置或其他应用窗口。
  排查中捕获的意外焦点已由采样器立即结束目标并如实记录。所有设备行为仅在隔离内存替身中进行，没有真实 MIDI/SysEx。
- 未验证/限制：configuration、output、precision 仍必须前台，本轮不运行，原因与原流程见能力表；
  builtin_names 固有英文断言没有改成中文。系统原生菜单/确认呈现和 Return/Escape 快捷键仍由原前台路径覆盖，离屏仅验证同一视图/动作及状态。
- 与 PLAN 的偏离：为满足严格不抢焦点，增加仅测试启用的非激活呈现适配；普通产品 UI、数据格式、公开合同不改。
  未改模拟侧禁改文件与冲突热点。fetch 后 rebase 到 d8e15a4，依赖锁未变，无需 update；保留远端新鲜 XCTest worker 汇总实现。
  当前旧任务提交号为 F1 74b4925、F2 62e68d8、F3 首次交付 397bb77；历史旧号保留作追溯。

- 最终检查：Swift 五模块全部 PASS，545 项、失败 0（PluginHost 11、AgentCore 271、AgentConsole 170、
  ProviderDomain 26、ProviderAdapter 67；545 个独立 XCTest 进程，120.668 s）。BuildWorkflow 124 项、失败 0；
  Python SDK 6 项、失败 0。build、双语离屏 smoke、全部上述可离屏脚本、域边界、命令校验、compileall、
  全仓格式检查及暂存 diff 检查通过。双语 strings 未新增，plutil 首次沿用旧 Core 资源路径失败，
  改为实际 Foundation 资源路径后两份均 OK。格式器改动已重新暂存并复跑；没有修改任何现有测试断言。

### F1–F3 最终提交索引

- F1：`74b4925`，F2：`62e68d8`，F3：通知/参数部分 `397bb77`，严格连接验收续作 `17aca89`。
  以上均已 rebase 到 origin/main 的 `d8e15a4`；历史旧号与中间失败记录保留。
- F1–F3 按本计划范围完成；F2 的三个必须前台脚本、名称脚本的英文语义与 F3 测试专用呈现限制以能力表为准。
  F4 未处理；没有真实设备连接或真实 MIDI/SysEx，没有 push/tag。
- 本次索引只改 PLAN.md，补齐已存在实现提交的真实编号；不修改实现、测试、验收步骤或原始结果。
  对应已验证实现：五模块 545 项、失败 0；BuildWorkflow 124 项、失败 0；SDK 6 项、失败 0。
  App 场景均为上述离屏记录，没有前台验收；原生系统菜单/确认呈现与三个前台脚本仍未验证。

- 索引提交前复查：五模块再次全部 PASS，545 项、失败 0，545 个独立进程、116.695 s；
  BuildWorkflow 再次 124 项、失败 0；域边界、命令校验、全仓格式和暂存 diff 检查通过。
  仅文档索引变动，复用 17aca89 的上述 build/离屏 App 场景证据，不新增前台运行。


## 设备接回本机后的推进（2026-11-13）

- 用户授权“提交并推送全部，并继续开发”；此前六项本地提交已同步到 origin/main（679db64），没有打标签。
  F1–F3 的不接实机范围已结束；后续只读实机检查依本次新授权推进，设备预设/数值写入尚未执行。
- 本机只读枚举：输入 Port 1/2，输出 Port 1/2/3；IOUSB 含 BCRDescriptorProbe override-v1 标记。
  不把“已枚举/有标记”写成全部传输或驱动可靠性通过。
- 实机只读检查成功：BCR2000 1.10、Device ID 0；Port 1 身份与 108 条 CC 快照回复，inputDropped=0，writes=[]。
  临时预设 554 个完整帧、108 条快照；56 个旋钮定义、52 个按键定义，.lock on、.request off。
  所发仅身份、快照及临时预设读取请求，没有 CC、预设选择、BCL/永久存储写入。
- 当前 App（昨天启动的旧进程）通过只读 MCP 核对 source=mock、motionSafety=disconnected、learningControl=null。
  其 get_status 缺少新连接确认字段，故没有直接切实体模式；请用户手动退出并启动已构建最新版。
- 复用 BCRProfileTool 对本次捕获离线转换，编码器/按键两种结果均为 108 项；52 按键缺项 0、不支持 0，
  全部 108 个 MIDI 身份与现有本机映射一致。原 hardware-map/surface-configuration 文件哈希前后相同，没有安装暂存结果。
  原始捕获、映射及暂存文件只保留忽略的 build/hardware-validation/readonly-20261113-104716；不入 git。
- B1-D 下一步（执行前记录）：用户表示可配合实机操作；保持 USB 连接，手动退出旧 App、启动最新版，
  暂不点确认按钮，目视确认是否弹出同步方向窗口及 LED 是否保持原样。此项需要用户看到真实窗口/设备，
  由用户手动前台操作；Agent 不启动前台 App、不发系统键盘事件、不触碰其他应用。
  当前仅等观察结果，不把旧进程、Mock 或只读回读当成 B1-D 通过。
- 未完成：B1 全套拔插/读硬件/写入、B2 功能按键与锁图标、B3/B4 视觉/时间校准；C1 远端驱动情况未变，
  本机设备接回不等于 ethanmacair 驱动已修复。后续结果逐项追加，失败亦保留。

- 本轮记录验证：MacDiagnostics 31 项、Swift 五模块 545 项（11/271/170/26/67，126.810 s）、
  BuildWorkflow 124 项、SDK 6 项均通过，失败均为 0；域边界与命令校验通过。只改文档，未改 App 或测试断言。
  原生 App 的启动操作交由用户，不启动额外前台或离屏测试 App，不替换用户正在使用的进程。


### B1 连接现场推进（2026-11-13，基线提交 c5347d5 之后）

- 用户确认截图中的当前软硬件一致；MCP 为 hardware/Port 1/confirmation=none，连接无错、反馈丢弃 0、外部输出关闭。
  截图只覆盖顶部当前组；首次启动确认前观察与当时选择的按钮未逐项取得证据，B1-D 仍未整体记作通过。
- 已完成一次用户手动 USB 拔插：MCP 采样 hardware → mock/disconnected → mock/connected/pending；
  用户确认重新弹窗、确认前灯环未改动三项正常。没有 App 自动切回实体或自动写入的声明，实际保持 Mock 等确认。
  私有日志为 build/hardware-validation/hotplug-20261113-105849/status.jsonl，反馈丢弃全程 0、外部输出关闭。
  此项只覆盖连接清单 C 的步骤 1/2 这一次连接流程，不覆盖 C3“写入并连接”、按住拔线或休眠。
- 下一步执行前记录：用户在真实确认窗点“暂不连接”，转动任意硬件旋钮后再选实体并点“按硬件现状连接”。
  Agent 只读 MCP 监测 declined → hardware，待用户观察数值是否跟随设备；不主动写回或替用户点击。
  真实窗口由用户手动前台操作，需要观察确认窗和设备；Agent 不启动前台 App、不发送系统键盘事件。

- 暂不连接/读硬件通过：用户完成指定操作并反馈全部正常；采样捕获 declined/mock 后重新确认并进入 hardware。
  诊断保护下的只读快照进一步核对 App 56/56 旋钮值一致、输入丢弃 0，诊断会话已关闭。
  私有结果为 build/hardware-validation/app-read-compare-20261113-110321/report.json；没有任何 CC 或预设写入。
- 下一步执行前记录：确认本机 52 个按键映射仍为仅显示后，请用户按下/松开一个顶部 PUSH 和一个 B1 按键，
  目视软件按压/释放及 Agent 未启动；以只读 console_events 捕获输入，不发送合成输入或系统键盘事件。
  此项是用户手动前台观察，不启动额外 App；不据此假定已验证全部 52 个按键。

- 按压显示两类样本通过：用户确认顶部 PUSH 与 B1 按键按下/松开正常，未启动 Agent；仅覆盖本次各一个样本。
  最初将 console_events 误解为仅记录业务接受输入，已更正：实际捕获顶部 PUSH/B1 各一对 control.raw（127→0），
  accepted=false，与仅显示相符。原始 MIDI 身份只放私有日志，不入 git；结合用户观察验证本次两类样本。
- 下一项执行前记录：用户按住 B1 键时拔 USB，再松手，检查是否清除按下状态；重插后先不确认，
  再在设备保持连接时手动退出、重开 App，检查确认窗及确认前 LED 不变，最后停在确认窗。
  这些现场步骤由用户主动前台操作，Agent 只读状态；不启动/激活 App，不发送系统键盘事件或设备写入。

- 按压日志补充：build/hardware-validation/button-input-20261113-110443/events.jsonl 实际捕获 4 个 control.raw，
  两类按键各 127→0、source=hardware、accepted=false；最初“事件为空”的说明是等待操作时的中间状态，已纠正。

- 用户确认按住 B1 键拔线、松开后无残留按下状态；重插等待后手动退出/重开 App，重新弹确认且确认前 LED 未变。
  连接清单 E2 与 D 本次现场样本通过；状态记录中也观察到 hardware → mock/disconnected → mock/pending，
  及 App 手动重启期间 MCP 暂不可达。该暂不可达是重启阶段，不作为设备故障，前台操作均由用户完成。
- 下一项执行前记录：请用户拔 USB 后手动重启 App，检查无确认窗且 Mock；设备选择实体时检查缺端点提示，
  再插 USB 检查确认窗/灯环不变，最后按硬件现状连接。此为连接清单 A 的现场路径，无软件或设备写入测试。

- A 路径通过：用户确认拔 USB 后重启无确认且 Mock、选择实体有缺端点提示、重插弹确认/灯环未改、按硬件现状连接正常。
  对应有限状态记录为 build/hardware-validation/held-restart-20261113-110857/status.jsonl，最终回到 hardware、error=null。
- C3 写入方案执行前记录：已私有保存全部 56 个旋钮基线（56/56 一致），目标为普通独立参数 E1-1，原始值/参数值 17，临时值 32。
  用户明确允许此方案：切 Mock 后只改此参数，再由用户点击“写入并连接”；该按钮发送软件当前整批控件值。
  前后校验其他 55 个不变，之后只恢复 E1-1=17 并回读；外部输出关闭，不写预设，不触发 Agent 或改其他应用业务参数。
  原始基线/方案在 build/hardware-validation/write-connect-preparation-20261113-111127，不入 git。
  若切源/预检发现其他值或路由变化则停止写入，不以自动覆盖其他参数来满足预期。

- C3 暂存检查通过：Mock 软件 E1-1=32、设备仍为17，硬件全56项保持基线、软件其他55项未改。
  已请求用户点击真实“写入并连接”，后台只读等硬件状态后比较56项；finally 经 App 正常参数效果管线恢复 E1-1=17，
  只恢复本测试的参数，再读回验证56项，不自动覆盖其他应用参数；记录结果后才判定通过。

- C3 自动回读通过：用户点击写入后 source=hardware，E1-1=32/其他55项原值，56/56；
  finally 通过 App 恢复 E1-1=17，再读56/56一致，诊断会话已关闭。没有直接CC探针旁路或预设写入，
  result.json 在上述私有目录，尚等用户灯环变化/恢复的目视确认；不把协议回读扩大为视觉通过。

- C3 视觉未通过：用户反馈 17→32 变化不明显，明确不确认当前验收通过。保留上轮协议回读/恢复56/56的原始结果，
  不将其记为 C3 整体完成，也不以用户尚未确认替代通过。
- 重新执行前记录：用户要求扩大灯环变化；沿用同一普通 E1-1（下方三排第一排最左），当前已恢复17，
  改为127并至少保持8秒后恢复17。重新保存全56项基线、Mock暂存与确认前设备未变证据；
  仍由用户点击真实“写入并连接”，全程外部输出关闭，不动其他参数或预设，分别记录回读与用户目视结果。

- C3 大幅重测通过：重新暂存 E1-1=127，确认前设备仍17、其他55项均保持基线；用户点击“写入并连接”，
  至少保持8秒后恢复17。用户明确反馈“清楚看到变化并恢复”。协议回读同时为写入56/56、恢复56/56，
  诊断会话关闭，最终 hardware/Port1 在线、confirmation=none、error=null、反馈丢弃0、外部输出关闭。
  私有证据为 build/hardware-validation/write-connect-preparation-20261113-111708/result.json。
  上轮17→32视觉未通过的记录保留，不合并成一次成功；本次只验证 E1-1 的大幅视觉变化及其余55项数值未变，
  不扩大为所有灯环模式、所有值边界或长时间压力测试。
- 本轮 B1 连接清单 A–E 现场路径完成：用户手动操作真实窗口/设备，Agent 只读观测，C3 使用用户明确授权的实际写值/恢复。
  没有预设/BCL或永久存储写入，没有启动Agent/外部执行端，没有额外启动/激活App或发送系统键盘事件。
  B2 启用业务按键/锁图标、B3 灯节奏、B4 显示时间及其余 HW 项仍未验证；不更改相关默认设置。

- 记录收尾验证：Swift 五模块全部PASS，545项、失败0（11/271/170/26/67，545个独立进程，130.185 s）；
  BuildWorkflow 124项、SDK 6项均通过、失败0；域边界、命令校验、全仓格式及暂存diff检查通过。
  本项只更新 PLAN、硬件清单/实测记录、TODO/ROADMAP，未改App、公开合同、产品数据格式或任何测试断言。
  没有额外构建/启动App或前台脚本；本轮前台均为用户执行上述真实窗口步骤，原因与观察分别已记录。
  原始捕获、MIDI身份、用户映射和测试脚本保留在本机忽略目录/临时目录，不提交。最终待提交记录只含观察与汇总。


### B2 对齐后行为现场执行（2026-11-13，9575c0a 之后）

- 用户授权直接开展下一项，按此前建议先验证单个按键、保持外部输出关闭；不连接真实执行端。
- 只读预检：实体 Port1 在线、confirmation=none、error=null、诊断关闭、未学习、反馈丢弃0；motionSafety=disconnected。
  B2-1 为 arm.enabled 的 toggle，当前0；B1-1 为Agent主动作，本轮不按它。52个按键均为仅显示。
- 已将硬件映射、软件配置、显示资料、既有恢复点及对应预设备份复制至私有忽略目录作为恢复副本；不安装或修改它们。
- 第一步执行前记录：用户打开“对齐设备预设”只读预览，等待完成后关闭，不点击写入或旧恢复点；
  检查右侧 STORE/LEARN/EDIT/EXIT/PRESET 锁图标。读取会刷新旧显示资料缺少的 locked 元数据。
  真实窗口由用户手动前台操作以便目视；Agent不启动/激活窗口、不发系统键盘事件。

- 用户确认锁图标已出现，并明确允许批量启用按键以提高验收效率；当前后端为Mock（8槽位），不会启动真实Codex任务。
- 用户新增显示要求：预设锁定后，软件LED空闲显示应尽量与硬件的当前预设一致。只读AX实测当前软件LED为----，
  同时新读显示资料 locked=true、已确认编号1、同名候选[1,8]。未知编号不能因锁定而猜测。
- 新增回归先复现：名字刷新失败、随后只读读到同名锁定预设时，显示资料保存了已确认编号但LED模型没有恢复，
  2项测试中1项失败（两个断言失败）。最小修复仅在fresh锁定读取/同名确认缓存/当前编号缺失时恢复已确认编号，
  不改变按键或旋钮短暂显示、传输跑马灯、未知编号策略、设备协议或用户数据格式。
  新增3项回归覆盖恢复编号/短暂值后返回、不同名称不复用、未锁定时不额外推断。聚焦3项已PASS。
  一次新增测试的输入64与初始反馈相同，被既有回显过滤；改用不同值100后通过，没有改原有断言。
- 已核对既有恢复点：map v7、108项，全部MIDI身份与当前一致、52项仅显示。其设备预设为lock off；
  当前锁定备份与它还存在顶部灯环样式差异，恢复时应按真实原样反映，不能声称只改变锁标志。
  当前所有资料及既有恢复点/对应预设已有私有恢复副本。继续准备通过现有App还原/对齐流程测试，不另开设备写入旁路。

- 用户现场明确反馈“硬件P- 1软件----”，与只读AX的软件LED值、已确认缓存编号1一致，显示缺口成立。
  用户同时要求批量启用多个按钮；后端已核实为Mock，批量测试仍保持外部输出关闭，后续恢复原仅显示状态。

- 新版检查通过：五模块548项（新增3项）、失败0，Console 173项；BuildWorkflow 124项、SDK6项通过，
  build/双语离屏smoke/离屏连接全流程通过。smoke采样没有目标激活或可见窗口，但用户前台切换且40次焦点读取失败，
  不声称该次前台全程未变；连接377样本前台稳定、目标未获焦点/不可见，读取失败1次。日志保留。
- CONTROL_MAP 冲突热点只补充用户要求的锁定预设编号显示规则，作为本显示行为修正必须的文档同步；不改控件身份/合同。
- 设备备份比对已完成：既有原预设与当前锁定预设均554帧，差异为锁标志1处、顶部灯环模式8处、按键easypar行为18处，
  无MIDI身份变动，恢复点map v7/108项/52仅显示。两份完整预设及host资料均已私有备份。
  后续使用正常App“恢复原预设→批量启用并对齐→恢复→默认选项重新对齐”路径，完成锁图标消失/出现与批量功能，
  最终恢复当前锁定/52仅显示的初始状态；恢复原样时灯环样式、按键行为暂时变化属于真实恢复内容，不冒充只改锁标志。
- 下一步执行前记录：用户手动重开新构建、按硬件现状连接，再只读打开/关闭预览，核对空闲软件/硬件均P- 1。
  前台由用户操作以观察真实屏幕；Agent不启动前台、不发系统键盘事件。其余验收保持原范围，未知编号仍不猜测。

- 用户已确认新版空闲LED显示修复正常；新增要求优化跑马灯，当前现场观察为顺时针、约每秒2圈。
  该观察更新此前2026-11-12的逆时针描述；旧记录保留为历史，本次采用最新现场信息，速度仍是目测估计。
- 按新要求将12段轮转改为顺时针、2圈/秒（24帧/秒），左右两边拆成独立上下段，避免原先两帧重复点亮同一整条边。
  新增方向/0.5秒周期回归。原动画覆盖测试的12Hz硬编码采样在24Hz下会混叠，仅将其采样输入改为标定帧率，
  “覆盖全部12段”的断言结论不变；这是新动画标定需求的测试适配，不删除验收。其余既有断言未改。
  动画仍仅在传输busy时运行，不增加空闲轮询；显示保持时间0.8秒不变，B4精确测量仍待做。

- 为恢复原预设（解锁）后也保持已确认编号显示，进一步统一“fresh同名预设读取→恢复已确认编号”的状态同步，
  不将恢复编号限制在locked=true。未锁定的新回归改为验证同名已确认缓存恢复；另加未知编号保持----的回归。
  这沿用既有同名已确认缓存策略，不从锁状态推断编号；无数据格式或Provider合同变更。

- 最终动画构建/双语离屏smoke通过：54样本前台稳定、目标未获焦点/无可见窗口、焦点读取失败1次。
- 批量验收执行前记录：用户手动重开动画新版，按硬件现状连接，再用设备菜单“恢复原预设”；
  该正常App路径会逐行写临时BCL并恢复既有map，暂时还原顶部8处灯环模式、18处按键行为并解除锁定，
  不改MIDI身份、软件配置或永久存储。等完成后观察锁图标消失与新忙碌动画，先不按任何实体业务键。
  下一阶段重新对齐并批量启用，再恢复/默认重新对齐回当前锁定与52仅显示状态；MCP只读监测，操作由用户前台完成。

- 动画合入后的最终软件回归：五模块550项、失败0（Console175；550个独立XCTest进程，165.022 s）。
  新版离屏连接脚本完整通过，367样本目标未获焦点/无可见窗口；用户前台切换、67次焦点读取失败，均保留，
  不声称该次前台全程稳定。双语离屏smoke54样本前台稳定、焦点读取失败1次；未启动真实硬件测试App。

- 显示修复与动画变更已完成软件验证，先独立提交可审查结果；B2 批量按键/恢复后解锁的现场步骤仍等待用户完成，
  不将未返回的恢复操作或新动画目视确认写成通过。当前没有由Agent执行额外设备写入，所有按钮仍是初始52仅显示。
  原始资料、前后台审计和全部失败记录保留；后续现场结果另行追加。

- 用户在软件2圈/秒版后要求“速度变为现在2倍”，并明确不再单独验证跑马灯、直接继续下一项。
  软件标定更新为顺时针4圈/秒（48帧/秒）；这属于用户视觉调节，硬件原目测约2圈/秒不被改写成精确4圈/秒。
  4圈/秒不再安排独立人工动画验收，软件回归仍执行。当前实例可继续做B2按键测试，动画新版随后续启动生效。

- 批量测试前再次核对：目前仍locked=true/52仅显示/restorePoint存在，尚未实际恢复；源hardware、外部输出关闭、backend=mock。
  为提高效率，用户在同一现有实例完成“恢复原预设→对齐并勾选启用已分配功能→写入设备”，不为动画另行重启或验收。
  批量启用后只测试B2-1使能及B1的Mock Agent动作；B2-2至B2-5绑定其他应用，不在本轮触发。
  当前步骤用户手动前台操作，Agent仅观察map/锁标志/输出状态；尚不请求按任何实体业务键。

- 用户新增现场观察：写入设备时硬件跑马灯逆时针、约1圈/秒。与此前未明确操作阶段的顺时针约2圈/秒分别保留，
  不用新观察覆盖旧观察，不将“可能存在不同样式”扩大为已证实的读/写方向规则；本次只记录，不改动画参数。
  软件4圈/秒仍是此前用户要求的视觉调节；B4后续应按读取/写入/回读分别对照，暂无精确计时或逐帧结论。
- 用户明确确认批量启用已完成，恢复后锁图标消失、对齐后出现，符合预期。下一步只测B2-1使能和B1-1 Mock Agent，
  不触发B2-2至B2-5的其他应用功能；继续保持外部输出关闭。尚不将设置完成计作动作执行通过。

- 批量启用状态已核对：locked=true、map 0项仅显示（52键已启用）、backend=mock、8槽位初始idle、arm.enabled=0，外部输出关闭。
- 用户确认B2-1两次切换完成；原高频状态观察脚本在操作前因MCP读取超时退出，不能冒充连续状态记录。
  随后只读补采console_events成功（dropped=0）：B2-1正向按下两次分别mapped_value=1/0，松开不重复切换；
  B1-1有一次完整按下/松开、accepted=true，当前Mock槽位1 waitingApproval/progress0.6，其他7槽idle、外部输出关闭。
  尚未发生第二次物理按压，不把“等待批准”误记为中断或故障；请用户再按B1-1批准Mock演示后完成，未触发真实Codex审批。
  观察改为低频并保留读取失败，后续原始事件/状态均留私有目录。

- 4圈/秒版软件检查：五模块550项/失败0（Console175，550进程，200.812 s）、BuildWorkflow124项/失败0，
  build和双语离屏smoke通过（39样本，目标未获焦点/无可见窗口，前台稳定，焦点读取失败1次）。
  最新受影响连接UI脚本在读取主窗口处失败（AX -1719）；同时前台PID179确认为loginwindow，当前图形会话不满足已解锁桌面条件。
  该次验收未通过，不归因于动画正确性、不改断言绕过、不连续盲重跑；待用户解锁再复跑。
- 当前待用户配合：Mock Agent1仍等待批准；原180秒低频观察有3次读取超时，未捕获完成，日志保留。
  已请用户回到解锁桌面后按一次B1-1完成Mock批准，再继续恢复52仅显示与原锁定状态。
  B2尚未整体完成，不能把显示修复/设置成功或使能键通过扩大为完整B2验收。

- 用户返回后恢复执行：只读核对仍hardware/Port1在线、锁定true、52键临时启用、arm.enabled=0、外部输出关闭；
  Mock槽位1 waitingApproval、其余7槽idle。先完成用户本地B1-1批准动作，再恢复测试前设置；未重复启动任务。
  重新开始低频观察并在解锁桌面复跑上次未通过的离屏连接验收，仍不要求单独人工验证跑马灯。

- 用户明确确认再次物理按下B1-1后Mock Agent1已完成；只读状态复核completed、backend=mock、外部输出关闭、使能0。
  只批准Mock演示，没有真实Codex审批或外部执行端。补采当前输入journal保留在私有目录。
- 恢复执行前记录：用户通过现有App恢复原预设，再重新对齐，明确不勾选“启用实体按键的已分配功能”，
  其他默认选项保持，恢复初始锁定和52键仅显示；不再按实体业务键，不更改其他应用的功能分配或数据格式。
  所有真实窗口均由用户手动操作；Agent只读观察、最终核对，再提交推送本项结果。


### 审查修复：预设恢复、缓存与动画（2026-11-13）

用户要求直接修复全部审查项，并授权设备持续供测试。本轮保全此前未提交改动及私有恢复资料，先用隔离假设备验证；没有为了复现危险条件向真机写入。

| 审查项 | 修复与验收依据 |
| --- | --- |
| 1 恢复上下文 | 限实体/连通/支持预设读写/非学习；保存端点身份，跨每个异步步骤复核同一路由；写前核对名称、设备ID及已知当前预设定义，忽略普通运行值变化但不忽略其他定义；旧点缺校验上下文则保留备份、禁自动写入 |
| 2 恢复回读 | ACK 后完整读回，逐行规范化比较（仅允许编号区块顺序变化），通过后才安装并确认保存映射、弹出恢复层级；失败保留恢复点 |
| 3 编号缓存 | 先读新名称/候选集并清除当前显示编号；候选改变、查询/解析失败或候选过多均不留旧号；主动载入编号另外绑定当时名称和路由，不能跟随改名后的槽位 |
| 4 重址确定性 | 优先保留已学习的重复地址拥有者，其余按按钮号升序；多轮/不同区块顺序回归相同 |
| 5 恢复层级 | 追加平坦历史，成功恢复逐层弹出，最近5份之外保护所有层级引用的文件；旧资料不销毁，不推断其缺失的设备上下文 |
| 6 后续学习 | 映射已变时先只读提示，取消不写；明确确认后另存当前映射，再恢复；确认期间和最后一次异步查询后的再次变化都阻止覆盖 |
| 7 可用性/进度 | 菜单和窗口均按同一条件禁用并显示原因；直接调用不可用操作也给可见提示；逐帧恢复进度和单独回读阶段 |
| 8 不可变写入合同 | 对已确认 plan.lines 完整回读比较，保留所有设置/值；不再用当前 configuration 重算“无修改”。预览后改映射/配置须重览，写入过程中配置改变不篡改校验合同 |
| 9 其他 | 删除无用 mapBeforeAlignment；分配避开53–64已用地址；无ACK时不创建新的可恢复层级，保留此前层级；另加备份摘要和设备ID防篡改检查 |
| 10 文档/动画 | 读取/回读使用用户调节的顺时针4圈/秒示意；写入使用现场观察的逆时针约1圈/秒。按操作传递动画上下文，重叠传输按token结束；不再说所有操作统一样式 |

- 聚焦回归已覆盖原有流程及新增保护；最初编译发现默认参数闭包调用缺少read参数，已修正。
  新增“未学习重复地址”的测试最初误要求自动学习已有键；改为检查设备BCL保留升序拥有者及另一键重址，未改变既有学习策略。
  上轮未提交的不安全“同名缓存直接恢复编号”已移除；新增测试按审查要求验证失败时保持未知，不保留错误预期。
- 用户实机资料只读补采：当前预设554帧、CC快照108项，诊断会话已关闭，没有预设写入。
  映射108项与B2前完全一致、52键仅显示、使能0、外部输出关闭；56个软件值与基线一致，56个设备值与软件一致。
- 原“配置字节完全未变”审计断言失败已保留并查明：现有App保存将配置v4迁至既有v7，68个参数仅增加externallyProtected，
  其中既有使能保护为true，其余false；新增空pages/macros。70个分配、参数ID/名称/数值范围/默认值/写权限等均未变。
  本轮没有修改SurfaceConfiguration版本或迁移实现，也没有降级覆盖用户文件；原v4私有副本保留，不能声称配置字节未变。
- 用户恢复/对齐前台操作与此前失败记录均保留；本轮软件检查一律离屏，不发送系统键盘事件，不打开其他应用窗口。
  新恢复元数据为可选字段，兼容读取旧文件；旧点缺少验证字段不能悄悄补成可信身份。这是审查安全修复所需的内部元数据，不改变Provider合同或硬件映射格式。

- 失败恢复边界补充：未把任意异常/部分回读保存成可信上下文；只接受操作前原始文档、完整已确认目标，
  或已授权恢复尝试后的同一备份目标。未知的同名文档仍拒绝写入；新增2项回归验证异常文档拒绝及回读失败后的安全重试。
  一次编译发现throw表达式位于短路操作符内需显式try，已改为顺序guard；最终聚焦恢复30项（25安全+5既有流程）通过。
- 系统焦点接口曾返回-25204（权限正常），用户将现有BCR窗口前台后仍不可读；已撤回该排查要求，未增加前台测试或弱化审计。
  后续纯离屏复跑接口恢复：中文case-96p48kae（283样本）、英文case-2pjr1_z9（274样本）均完整通过，
  各自前台稳定、targetWasFront=false、focusedTargetSamples=0、visibleSamples=0、焦点读取失败1次；此前失败照实保留。
- 最新完整Swift回归589项、失败0，五模块全部PASS（11/276/209/26/67；589个独立进程，130.690 s）。
  原连接验收22项assert全部保留，新增2项取消/替换前设备与映射不变的检查；中英文真实AX路径均为隔离假设备、显式offscreen。

- 上一轮提交前最终检查：589项Swift/失败0，五模块11/276/209/26/67，589个独立进程、165.372 s；
  BuildWorkflow124项、SDK6项均通过；构建/双语离屏smoke/中英文离屏连接恢复验收通过。
  新确认文字截图检查发现单行截断，已加完整换行并重新构建、跑全套和中英文AX流程；原始22条验收assert保留。
  用户要求先提交本轮，再修复新发现的9项（读取取消排流、不可用层级、同名编号与存储体积等）；这些新问题不记为本轮已解决。

### G1 第 1–3 步 / G4 第 1–2 步（2026-11-14）

- `377a983`：新增 MCP 工具 `get_preset_alignment`、`preview_preset_alignment`、`apply_preset_alignment`、`restore_preset`、
  `dismiss_preset_alignment`，与对齐窗口同一流程；需要 parameterWrite、deviceControl、configurationWrite。全量 647 项、失败 0。
- 新增 `tools/time_bcr_transfer.py`（只读请求或纯监听，只输出行数/时间）。
- G4：真机 `list_midi_endpoints` 列出 `BCR2000` 一进一出；`set_midi_endpoints` 后 `hardwareConnection.connected=true`。
  观察：改端口后设备源回到 mock，需再调 `set_device_source hardware`（是否应保持实体源，未定）。拒绝路径未在真机验证。
- G1：五类只读操作与一次完整对齐写入均已记录，见 `docs/HARDWARE_VALIDATION.md`“G1 跑马灯分场景观察”。
  “每行一步、12 步一圈”未证实也未推翻；读取中目视的短暂加速无计时对应。写入取数改用被动监听设备确认，未改 App 写入路径。
- 未做：G1 第 4 步（慢速写入判定每行步数），需用户同意新增写设备路径。设备当前保持对齐后的临时预设，可恢复。
