# 界面打磨与校准清单

建立：2026-11-12。按用户确认的顺序：先做 14，再做 1–9。完成一项勾一项，全部完成后删除本文件。

## 需要设备

- [x] 14 进度条（bar）与居中（pan）灯环逐灯对照真机校准：24 个值全部一致，软件无需修改。
- [ ] 13 [硬件连接实测清单](HARDWARE_CONNECT_TEST.md) 的 A–E（连接确认）与 G（Agent 按键灯）。

## 界面打磨（不需要设备）

- [x] 1 功能配置迁移提示每次启动都出现：保留“迁移后不自动改写原文件”的既有约定，横幅新增“保存升级”按钮，写回前原样备份，保存后不再出现。
- [x] 2 横幅占用高度：无操作按钮的普通提示 6 秒后自动消失，警告/错误/可操作提示保留；横幅最多两行。两条未合并（一条是持久化状态，一条是即时提示）。
- [x] 3 内置示例名称在面板、检查器、标题栏按界面语言显示，不改存储值（`56c4aa7`，review 修正见下）。
- [x] 4 右侧一栏去掉 EXIT 与 USER 之间的弹性空白，各组紧凑排列并加“设备键”分组标签。
- [x] 5 对齐/恢复收进面板标题旁的设备菜单，有恢复点时显示圆点（`93cd325`）。
- [x] 6 USER 键功能名 8.5 号、最多两行；未分配显示短横线。
- [x] 7 禁用的设备键带禁止图标；读取到预设 `.lock on` 时改为锁图标并说明如何解除。
- [x] 8 IN 灯在收到设备消息时闪烁（随帧刷新，不额外发布）；A/B 仍为对照显示。
- [x] 9 分组提示移入悬停说明，设备所在组在分组键上以圆点标出。

## 功能性（不需要设备，排在 1–9 之后）

- [x] 10 Agent 按键灯开关移到 Agent 设置页，带五态节奏预览（`a9e46f0`）。
- [x] 11 `get_status.hardwareConnection.confirmation` 返回 none/pending/declined（`7ae006b`）。
- [ ] 12 README 截图过时（无显示屏与右侧一栏）；重新截图需要屏幕录制权限。

## 移交给执行窗口的任务（3、5、10、11）

分工：执行窗口实现，审查窗口（原开发窗口）逐提交 review 后推送。全部任务不需要设备。
方案 3A、5A 是审查窗口的推荐方案，用户尚未逐项确认；如用户另有指示，以用户为准。

### 任务 3：内置示例名称跟随界面语言（方案 A，显示时翻译）

现象：英文界面下“J1 底座旋转”“机械臂”“使能”“参数 1”等仍是中文。原因：名称在创建配置时按当时语言写入
`surface-configuration.json`，之后不变。

做法：
- 在 `BCRExamples`（`Sources/BCRExamples/ConfigurationPresets.swift`）提供一个纯函数：输入已保存的名称，
  若它与某个内置名称在**任一受支持语言**下的文本完全相同，返回该内置名称在当前语言下的文本，否则原样返回。
  覆盖：机械臂 9 个参数名、分组“机械臂”“通用”、配置名“机械臂示例”及 starter 配置名、“参数 N”（N 为 1…8）。
- 只在**显示层**调用：面板单元格（`SurfacePanelView.swift` 的 `presentation(of:)`）、检查器
  （`ControlInspectorView.swift`）、标题栏配置名（`ContentView.swift` 的 `HeaderBar`）、“复位 X”标签。
- 不改文件、不改 `ParameterDefinition`/`SurfaceConfiguration` 的存储值；MCP、导出、`resetGroup` 的分组引用、
  配置库保持原文。用户改过的名称（与内置文本不完全相同）不翻译。

验收：单元测试覆盖中→英、英→中、用户自定义名称不变、未知名称不变；切换 `L10n.language` 后同一份配置的
显示文本变化而编码后的 JSON 不变。

### 任务 5：对齐/恢复按钮收进“设备”菜单（方案 A）

现象：实体模式下“对齐设备预设”“恢复原预设”两个按钮占用面板标题行，右侧说明文字被压窄。

做法：在 `SurfacePanelView.swift` 的 `header` 里把两个按钮换成一个小的 `Menu`（图标按钮，带 help 和
accessibilityLabel），菜单项为“对齐设备预设…”和“恢复原预设”。沿用现有的
`model.beginPresetAlignment()`、`model.restorePresetBeforeAlignment()`、`model.canAlignPreset`、
`model.canRestorePreset`、`model.presetRestorePoint`：不可用的项禁用；`presetRestorePoint != nil` 时菜单按钮上
显示一个小圆点。只在 `source == .hardware` 时显示。不改对齐/恢复的任何逻辑。

验收：现有 `PresetAlignmentFlowTests` 不改且通过；检查 `tools/verify_*_ui.py` 是否按旧按钮文字选择控件，
有则同步更新选择器。

### 任务 10：Agent 按键灯闪烁开关挪到 Agent 设置页

现状：开关在“设置 → 反馈调度”（`FeedbackSettingsView.swift` 里的“Agent 按键灯”一节），与反馈限速无关。

做法：把该节移到 `CodexAgentSettingsView.swift`（设置的 Agent 标签页），`FeedbackSettingsView` 恢复为不依赖
`ConsoleViewModel`（改回原构造方式，同步 `BCRAgentConsoleApp.swift` 的两处调用）。在开关下方加一个预览：
五种状态（空闲、排队、运行、等待审批、出错）各一个小灯，按 `BCRIndicatorBlink.pattern(for:)` 的节奏亮灭
（用 `TimelineView`，只在该页可见时运行）。不改 `setBlinksAgentLEDs` 与闪烁调度逻辑。

验收：`AgentLEDBlinkTests` 不改且通过；预览用到的节奏来自 `BCRIndicatorBlink`，不另写一份周期。

### 任务 11：MCP 可查询“等待用户确认连接”

现状：`set_device_source` 请求切换实体且会写设备时，`ConsoleViewModel` 的 `mcp.service.onSelectSource` 抛出
“需要在界面上确认同步方向”，同时弹确认窗。Agent 无法得知用户随后是否已确认，只能再次调用碰运气。

做法：让 `get_status` 能反映这一状态。**先核对约束再动手**：旧 Provider 1.0 的 Schema、错误语义和 14 组黑盒
不得变化（见 `docs/MCP.md`、`docs/PROVIDER_API.md`、`Schemas/`、`configs/verify_provider_blackbox.py`）。
- 若 `get_status`（`Sources/BCRMCPAdapter/SurfaceMCPModule.swift`）的结果对象允许新增可选字段且不破坏
  Schema 与黑盒，则在 `hardwareConnection` 下新增 `confirmation`：`none` / `pending` / `declined`，由宿主注入的
  回调提供（GUI 读 `pendingHardwareConnection` 与最近一次拒绝；无界面服务恒为 `none`）。
- 若新增字段会改动 Provider 1.0 Schema 或使黑盒失败：**停止，不实现**，在交接记录里写明冲突点，由用户决定。
- 不改 `set_device_source` 的拒绝行为与错误文本。

验收：新增测试覆盖 pending → 用户确认后 source 为 hardware、pending → 用户拒绝后 declined；
`verify_provider_blackbox.py` 14 组与 `Tests/BuildWorkflowTests` 全部通过。

### 不在本次移交范围

- 12 README 截图：需要屏幕录制权限，由用户或有权限的窗口处理。
- 13 及任何需要设备的验证：设备在远端且驱动未装好，见下节。

### 给执行窗口的提示词

```text
你在 /Users/ethan/Documents/BCR2000Dev（main 分支，SwiftUI/CoreMIDI 的 BCR2000 控制台）工作。
先读 AGENTS.md、CONTRIBUTING.md，再读根目录 UI_POLISH.md 的“移交给执行窗口的任务”一节，
按顺序实现任务 3、5、10、11。每个任务的现象、做法、文件位置和验收标准都写在那一节里，以它为准。

规则：
1. 只做这四个任务，不做范围外的重构。任务 11 先核对 Provider 1.0 约束，冲突就停下并记录，不要硬做。
2. 不需要也不要尝试连接设备；不发送任何 MIDI/SysEx。
3. 不改模拟侧文件：Sources/BCRProviderMCPAdapter/SurfaceControl*.swift、docs/SURFACE_*.md、
   configs/package_provider.py、Schemas/、Clients/。与其他窗口的冲突热点是 SurfaceSession.swift、
   SurfaceEngine.swift、docs/CONTROL_MAP.md，除非任务必须，否则不要动。
4. 所有新界面文字通过 L10n.text，并在 Sources/BCRFoundation/Resources/{en,zh-Hans}.lproj/Localizable.strings
   成对添加；改完用 plutil -lint 检查两个文件。
5. 每个任务一个本地提交（Conventional Commits，中文或英文均可），提交前：
   - git fetch origin；若远端有新提交且你有未推送提交，git rebase origin/main（不 merge、不 force）。
     远端若改了 configs/surface_plugins.lock.json，运行 python3 configs/surface_plugins_dependency.py update。
   - python3 configs/format_repo.py --staged（它改了文件就重新 git add 再跑一次）；git diff --check --cached。
   - 全量测试：swift test --build-path build/swiftpm > /tmp/bcr_test.log 2>&1，然后
     grep -E "Test Suite '.*\.xctest' (passed|failed)|Test Case .* failed" /tmp/bcr_test.log
     必须看到 5 个测试包全部 passed、没有 failed 的用例。不要只看输出最后一行，那只是最后一个包。
   - python3 configs/check_domain_boundaries.py；python3 -m unittest discover -s Tests/BuildWorkflowTests。
6. 只提交，不要 push，不要打标签。push 由审查窗口在 review 通过后执行。
7. 每完成一个任务，在 UI_POLISH.md 的“执行记录”一节追加：任务号、提交号、改了哪些文件、测试总数与失败数、
   没验证或有疑问的地方、与任务书的任何偏离及原因。如实写，失败或没做的也要写。对应清单项先不要打勾，
   由审查窗口 review 后勾选。
8. 遇到任务书没覆盖的取舍，选改动最小的做法并在执行记录里说明；涉及改用户数据、改既有测试断言、
   改公开合同的，停下记录，不要自行决定。
```

### 执行记录

#### 任务 3 — `56c4aa7`（rebase 前 `81f376d`）

- 改动：`Sources/BCRExamples/ConfigurationPresets.swift` 提供精确匹配中英文内置名称的纯显示函数；
  `SurfacePanelView.swift`、`ControlInspectorView.swift`、`ContentView.swift` 及检查器子视图
  `TriggerParameterEditor.swift` 接入；新增 `Tests/BCRAgentCoreTests/BuiltInNamePresentationTests.swift`。
- 验证：Swift 五包 506 项、失败 0；BuildWorkflow 71 项、失败 0；Python SDK 6 项、失败 0。
  域边界、命令校验、全仓格式、双语 strings lint、App build、双语 1200×760 startup smoke、
  隔离 Mock 下当前/旧版 MCP 冒烟全部通过。
- 未验证：没有人工逐控件视觉交互，没有设备/MIDI 实测。
- 偏离：现有 `L10n.language` 是进程内不可变常量（语言设置重启生效），测试用显式 language 参数在同一配置上
  验证中英显示变化与 JSON 完全不变，未改全局语言机制。额外覆盖检查器触发参数选择器，避免同一检查器残留中文。
  复用已有翻译键，无需新增 UI 文案。清单留待审查窗口勾选。

#### 任务 5 — `93cd325`（rebase 前 `e65d05e`）

- 改动：`SurfacePanelView.swift` 将对齐/恢复合并为实体源下的图标菜单，备份圆点、help、无障碍标签和稳定标识齐备；
  两个语言 strings 成对补文案。现有 `tools/verify_*_ui.py` 没有使用旧按钮文字定位，无需修改。
- 验证：Swift 五包 506 项、失败 0（`PresetAlignmentFlowTests` 原样通过）；BuildWorkflow 71 项、失败 0；
  边界检查、strings lint、格式检查、App build、双语 1200×760 startup smoke、隔离 Mock MCP 双版本冒烟通过。
  通过 App 自身的原生视图缓存渲染检查 1200×760 Mock 布局（未截取桌面）。
- 未验证：没有连接实体，没有实际打开实体源菜单操作设备。
- 偏离：无功能/策略变更。清单留待审查窗口勾选。

#### 任务 10 — `a9e46f0`（rebase 前 `1e2b84f`）

- 改动：`CodexAgentSettingsView.swift` 接入原开关与五态灯预览；`FeedbackSettingsView.swift` 移除 model 依赖并恢复
  350 高度；`BCRAgentConsoleApp.swift` 同步设置页与原生渲染调用。
- 验证：Swift 五包 506 项、失败 0（`AgentLEDBlinkTests` 原样通过）；BuildWorkflow 71 项、失败 0；
  域边界、命令、格式、双语 strings lint、App build、双语 startup smoke、隔离 Mock MCP 双版本冒烟通过。
  检查中英文 Agent 页及反馈页原生渲染；五种灯与标签均完整显示。
- 未验证：没有真机灯验证，未手动测量切走设置页后的刷新次数；实现以 TimelineView 的 paused 与页面出现/消失控制。
- 偏离：为避免预览被原表单挤到滚动区下方，将该节放在 Agent 页首；复用既有文案，无新增翻译键。
  未修改闪烁调度、开关持久化或既有测试。清单留待审查窗口勾选。

#### 任务 11 — `7ae006b`

- 合同核对：`MCPModels.swift` 的旧工具 outputSchema 仅要求 `data`，其内部 schema 为 `{}`；
  Provider 1.0 发布/内置 schema 均不定义 `get_status` 的内部结果。允许此项加法字段，无需改变任何 schema。
  未修改 `Schemas/`、`Clients/`、模拟侧实现或 `set_device_source` 的拒绝文本与语义。
- 改动：`MCPApplicationGateway.swift` 提供宿主确认状态回调（无界面默认 none）；`SurfaceMCPModule.swift`
  只读返回 confirmation；`ConsoleViewModel.swift` 记录当前端口的拒绝并在新请求、确认、换源或路由失效时清除。
  `docs/MCP.md` 说明轮询方式；新增 `HardwareConnectionStatusTests.swift`、`HardwareConfirmationGatewayTests.swift`。
- 验证：新增 4 项聚焦测试全部通过；最终 Swift 五包共 516 项、失败 0
  （ProviderDomain 26、ProviderAdapter 57、PluginHost 11、AgentCore 270、AgentConsole 152）。
  `verify_provider_blackbox.py` 14 组全部通过，输出在忽略目录 `build/ui-polish-blackbox11-final`；
  本地自包含验收件在 `build/ui-polish-provider11-final`（Debug/dirty 工作区验收件，未发布）。
  BuildWorkflow 71 项、Python SDK 6 项，失败均 0；域边界、命令、全仓格式、strings lint、
  App build、双语 1200×760 startup smoke、隔离 Mock MCP 双版本冒烟通过。
- 同步：提交前发现远端新增 4 个模拟侧提交，已将前三个本地提交 rebase 到 `caceb4c`，无冲突；
  按远端锁更新本地 SurfacePlugins 到 `8a9f3b31f6fe2d5c3bde171da305dc7059060de0`，并重跑全部最终验收。
  上述任务 3/5/10 的 506 项为各自提交前的原始基线结果；最终 516 项覆盖所有改动及远端合入内容。
- 未验证/疑问：没有实体连接、MIDI/SysEx 发送或实际 GUI 确认点击；连接流程使用全隔离假 MIDI 验证。
  编译时保留远端已有的 `Tests/BCRProviderAdapterTests/SharedSurfaceScenarioTests.swift:196` 多余 try 警告，
  本次未修改该模拟侧测试，也未引入新的编译警告。
- 偏离：pending 包含原有 300 ms 连接稳定等待期，避免拒绝调用后立即查询暂时返回 none；
  none 不代表同步成功，文档明确要求结合 source 查询。无新用户数据格式，无公开 schema/旧测试断言变更。
  清单未打勾，等待审查窗口确认。

#### 交接状态

- 任务 3、5、10、11 已实现并各有一个本地提交；另用文档提交补齐最后一个实现提交的编号与本记录。
  因提交号无法写入其自身提交，前几项记录随下一项提交追加；此为执行记录入库时机的唯一调整。
- 所有提交均在 main；未 push、未打 tag。审查窗口按上述四个实现提交 review 后决定勾选与推送。
- 任务 12 README 截图、任务 13 设备实测仍按本文件约定不在本次范围；未删除本清单。

### Review 结论（审查窗口，2026-11-12）

独立复跑：5 个测试包 516 项、失败 0；BuildWorkflow 71 项通过；域边界、双语 strings lint、全仓格式检查通过。
与执行记录的数字一致。逐提交读了全部源码差异。

- **任务 3：通过，修正一处缺陷。** 检查器的名称/分组输入框显示翻译后的文本，但写回的是用户看到的文本。
  英文界面下在“Robot Arm”分组框里输入一个字符再删掉，草稿的分组就从“机械臂”变成“Robot Arm”，
  应用后该参数被拆到新分组，而“复位”按键仍引用原分组（已用临时测试复现：分组变为
  `["Robot Arm", "机械臂"]`）。修正：新增 `BuiltInNamePresentation.editedName`，输入内容与显示文本相同时保留
  原存储值；补回归测试。执行记录里“不会弄脏草稿”的说法只对未编辑的情况成立。
- **任务 3 的遗留范围**：批量分配窗口（`BulkAssignmentView.swift`）、输出设置（`OutputSettingsView.swift`）和两条
  提示文案仍显示存储的原名。任务书只列了面板、检查器、标题栏，不算偏离；已列为 [PLAN.md](PLAN.md) 的 A2。
- **任务 5：通过。** 只换了入口，逻辑未动；菜单项的 help 在 macOS 菜单里不会显示，不影响功能。
- **任务 10：通过。** 预览与实际闪烁用同一时钟和同一节奏函数；离开页面即暂停。把这一节放在 Agent 页首是合理偏离。
- **任务 11：通过。** 只在未限定结构的 `data` 内加字段；拒绝行为与错误文本未改；拒绝记录在换源、断开、换端口、
  新请求时清除，旧弹窗的回调被忽略，均有测试。黑盒 14 组的结果取自执行窗口的记录，我没有重跑。

未验证：没有运行界面、没有设备。菜单、预览和确认状态都只有代码审查与单元测试的证据。

## 远端设备（ethanmacair）

设备 2026-11-12 起插在 ethanmacair（SSH 可达，登录用户 henrykang，仓库在 `~/Documents/BCR2000Dev`）。

- 现状：系统识别到 BCR2000 的 USB 与 MIDI 端口，但只读身份查询无回复。该机未安装 USB 描述覆盖驱动
  （BCRDescriptorProbe），OUT 端点包长仍为 4，只能收不能发。
- 已做（SSH）：只读采集 USB 描述 `build/original-usb-report.json`，编译 override 候选，生成
  `build/driverkit-probe/xcode-override` 工程（团队与该机上次 control 签署相同）。
- 阻塞：dext 签署报 `errSecInternalComponent`，SSH 会话与用户在桌面终端执行均失败；宿主 app 因此未生成。
  未安装、未激活任何扩展。下一步需在该机桌面排查签署（钥匙串对 codesign 的私钥访问授权，或在 Xcode
  图形界面里构建一次），再按 [DriverKit 记录](docs/DRIVERKIT_USB_PROOF.md) 的复核顺序安装并重新枚举。
- 远程开发方案（参照 XTouchCompactDev 的 SSH 桥接）在驱动可用前只有“只听不发”的价值，暂不开工。
