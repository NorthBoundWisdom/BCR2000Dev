# 开发规范

适用于所有开发者与自动化 Agent。架构与工具约束另见 [AGENTS.md](AGENTS.md)，
阶段计划见 [ROADMAP.md](ROADMAP.md)。

## 1. 分支、提交与推送

- **始终在 `main` 上开发和验证**。不创建分支、不使用 `git worktree`、不另外 clone 仓库来开发、
  验证或回测历史提交。只有开发者明确要求时才例外。
- 按“改 → 在 `main` 工作区跑检查 → 提交”的顺序推进。每个提交对应一次通过检查的工作区状态，
  不要事后拆分混在一起的改动。
- 工作区可能与其他开发者 / Agent 共享。开始前先看 `git status`；遇到不属于自己的未提交改动，
  不要覆盖、`stash`、`reset` 或擅自提交，先确认归属。推送后保持工作区干净。
- **每完成一个可验证的改动，就提交并推送到 `origin/main`**，不在本地堆积未推送的提交。
- 推送前先 `git pull --rebase origin main`；**禁止对 `main` 强制推送**。
- 版本 tag（会触发发布 CI）和 Release 只在开发者明确要求时创建、推送。
- 一个提交只做一件事；重构与行为变更尽量分开提交。

### 提交信息

采用 Conventional Commits：

```text
<type>(<scope>): <简短描述>

<可选正文：为什么改、影响范围、验证方式>
```

- `type`：`feat`、`fix`、`refactor`、`test`、`docs`、`build`、`ci`、`chore`、`perf`。
- `scope`（可选）：`core`、`surface`、`mock`、`midi`、`ui`、`agent`、`codex`、`build`、`docs`。
- 描述用中文或英文均可，祈使语气，不加句号，首行不超过 72 字符。

示例：`feat(surface): 支持编码器相对模式`、`fix(midi): 重连后重新发送全部反馈`。

## 2. 提交前检查

### 自动格式化

安装 SwiftFormat 和 Ruff（本轮验证版本为 SwiftFormat 0.64.4、Ruff 0.15.17），
并运行项目配置来启用版本控制内的提交钩子：

```bash
brew install swiftformat ruff
python3 configs/setup_local_project.py
```

配置会将本仓库的 `core.hooksPath` 设置为 `configs/githooks`。已有自定义钩子的开发者
应先合并自己的钩子；这是仓库本地配置，不影响其他仓库。

```bash
python3 configs/format_repo.py --all          # 全仓格式化（仅 Git 跟踪文件）
python3 configs/format_repo.py --all --check  # 只检查，不写文件
python3 configs/format_repo.py --staged       # 与提交钩子相同
```

Swift 使用 `configs/.swiftformat`（Swift 6、4 空格、120 列），Python 使用 `ruff.toml`。
其他 UTF-8 文本统一 LF、行尾空白与文件末尾换行，保留 Markdown 的双空格换行。
跳过 `configs/_vendor/`、二进制、符号链接及 Git 属性中标记为 `-text` 的文件。

提交时只检查暂存内容；需要修正时自动格式化完全暂存的文件，然后中止提交，提示重新
`git add` 并提交。部分暂存的文件若需要格式化，会在写入前停止，保留暂存区和工作区内容。
缺少格式化工具或工具执行失败会阻止提交并显示原因。

### 必需检查

```bash
python3 configs/format_repo.py --all --check
swift test --build-path build/swiftpm            # 必须全部通过
python3 -m unittest discover -s Tests/BuildWorkflowTests
python3 configs/validate_repo_commands.py .
git diff --check
```

改动 UI 时还需：

```bash
python3 configs/macos_workflow.py build
python3 configs/macos_workflow.py smoke
```

并在 1200 × 760（最小窗口）下实际打开应用检查布局，Mock 模式下走一遍改动涉及的交互。
检查未执行或失败时，不得写成“已验证”；在提交正文中如实说明。

MCP 控制接口（ROADMAP R8）完成后，每轮验收还要在运行中的 App 上执行 `tools/mcp_smoke.py`。
所有检查和验收都在 `main` 工作区的 HEAD 上进行。

编译警告视为问题，不引入新的警告。

## 3. 架构规则

- **分层**：物理控件 → 硬件映射 → 功能分配 → 参数状态。新概念先确定属于哪一层。
- `BCRAgentCore`：纯值类型、无 UI、无 CoreMIDI，可单元测试。状态转换都在这里。
- `BCRAgentConsole`：SwiftUI、CoreMIDI 生命周期、持久化与依赖装配。
  视图只渲染状态、发出意图，不直接发送 MIDI，不包含业务规则。
- 所有设备写回都通过 `SurfaceEngine` 返回的 `SurfaceEffect` 走 `SurfaceSession` 的效果管线，
  不另开旁路。
- 软件参数是唯一事实来源；硬件输入改参数，参数决定反馈。
- **Mock 与实体一致**：任何设备行为的假设必须同时体现在 `MockBCR2000` 中并有测试；
  实测发现差异时先修 Mock，再修引擎，并更新 `docs/CONTROL_MAP.md`。
- **不猜测用户的 BCR2000 预设**。实体映射只能来自学习；Mock 预设只描述 Mock。
- 失败必须可见（通知条、状态栏计数或监视器），不加静默回退。
- 涉及时间的逻辑把 `now: Date` 作为参数传入，便于测试。

## 4. 测试

- 每个新的状态转换、MIDI 消息形状、功能类型、配置校验规则都要有聚焦的单元测试。
- 双向同步相关改动至少补一条 “Mock → 引擎 → Mock” 闭环测试。
- 修复缺陷时先写能复现的失败测试。

## 5. 持久化与兼容

- 本地文件位于 `~/Library/Application Support/BCRAgentConsole/`，绝不提交到仓库。
- 修改 `HardwareMap` 或 `SurfaceConfiguration` 的编码格式时提升 `currentVersion`，
  并在加载旧版本时给出可见提示（或提供迁移），不得静默丢弃用户数据。
- 新增 `Codable` 类型对非法输入要抛错，不依赖 `precondition` 拦截持久化数据。

## 6. UI 约定

- 颜色、描边、面板样式统一使用 `Theme` 与 `panelStyle()`；LED 用红色以贴近实物。
- 面向特定场景的工作区面板（机械臂预览、输出读数等）标记为 `WorkspaceTab.isOptional`，默认隐藏，
  由用户从“面板”菜单启用；涉及安全读数的面板在相关功能运行期间必须保持可见。
- README 截图用 `tools/capture_readme_screenshots.py` 从隔离 Mock 实例重新生成，不手工截取桌面。
- 界面文字使用简体中文；控件简称沿用 `P组-序号`、`B行-序号`、`E行-序号`、`U序号`。
- 交互控件提供无障碍标签；可调节控件支持 `accessibilityAdjustableAction`。
- 破坏性操作（清空映射、删除参数、替换配置）必须二次确认。

## 7. 机械臂与外部系统安全

- 输出到执行端前必须经过：使能检查、软限位、单步变化量与速度上限。
- 适配器断线或超时立即停止输出并告警。
- 安全相关逻辑放在 Core 中并有测试，不放在视图或适配器回调里。

## 8. 文档

- 行为变化时同步更新 `README.md`、`docs/CONTROL_MAP.md`；完成或新增计划时更新
  `ROADMAP.md` 与 `TODO.md`。
- 不在仓库中写入密钥、绝对用户路径、生成的应用包、MIDI 抓包或本地映射文件。
