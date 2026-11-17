# GUI 虚拟控制台

显式虚拟模式让共享 SDK 的状态面板演示连接实际 `BCRAgentConsole.app` 窗口。
HTTP 显示写入与窗口旋钮使用同一个 Session 和 Mock 显示路径；参数、输入事件与显示各自记录。
来源始终是 `simulation`，档案为 `bcr2000.gui.virtual` / `1`，日志带
`gui_virtual_surface=true`、`physical_evidence=false`。这是软件演练。

普通 GUI 的默认启动与旧 MCP 设置保持原有行为。虚拟模式是独立启动选项，不能切成实体来源；
它不构造 CoreMIDI、旧 Keychain 凭据或外部输出 transport，也不加载普通应用的配置/学习 map。
硬件来源、端点、预设或恢复请求会撤销该虚拟 endpoint，显示清除结果保留在退出记录中。

## 构建并连接实际窗口

先构建应用，并指定交付件中的 SDK 1.5 runtime ZIP。输出目录必须尚不存在：

```sh
python3 configs/macos_workflow.py build --configuration release --distribution ad-hoc
python3 configs/run_gui_virtual_surface.py \
  --app build/app/BCRAgentConsole.app \
  --sdk /path/to/delivery/surface-control-sdk-1.5.0.zip \
  --output build/gui-virtual-demo \
  --protocol 2026-07-28 --duration 15
```

该启动器通过两条独立匿名管道传递 display 凭据与 ready/final 记录，随后启动真正的
`python -m surface_panel_demo` 子进程。命令不把 token 放入 argv、URL、日志、磁盘或旧 Keychain。
映射从该次实际 discovery 的稳定 control ID、反馈种类和范围生成，并以 `--mapping PATH`
交给 SDK；无需手写 MIDI 地址。`--protocol 2025-11-25` 也受支持。

`ready.json` 记录实际端口、provider/instance/profile、窗口可见性和临时 mapping 路径。
`cli-stdout.json` / `cli-stderr.json` 保留 SDK 的原结果，`stopped.json` 记录退出与清理状态。
演示结束后只清理此实例的显示、临时数据/偏好与其拥有的管道；ready 中的临时路径随后失效。

默认合同为 1.3。启动器显式加 `--input-event-capacity N`（1…65536）后，该 endpoint 使用
既有 1.5 输入保留能力；这不改变普通 GUI、独立模拟服务或实体服务的默认发现。
虚拟 profile 不声明 hold；未授予远程输入、renew 或 reset。

## 入口与权限

直接启动 `.app/Contents/MacOS/BCRAgentConsole` 时必须提供：

- `--gui-virtual-surface`
- `--gui-virtual-surface-token-fd N`：只读匿名管道，恰好 64 个小写十六进制 token 字节并关闭写端
- `--gui-virtual-surface-ready-fd N`：独立可写匿名管道，启动器负责读取
- 可选 `--gui-virtual-surface-port N`：默认 0，由系统分配；显式端口为 1024…65535
- 可选 `--surface-input-event-capacity N`

FD 类型、方向、重复与凭据长度/EOF 在 model、配置和 native adapter 创建前检查。
此模式与旧 MCP 凭据入口、集成/启动 smoke、独立业务模拟器及实体/owned-rehearsal 参数互斥。
LaunchServices 的 `open --args` 不提供所需的 FD 继承，应使用上述启动器。

display 凭据只看到 discover、snapshot、events、feedback；显式 retention 时多一个 input_events。
新 endpoint 不注册 Provider 1.0、设备管理、业务参数或 source/config 工具；旧 GUI MCP 在此模式永久关闭。
本地窗口的程序化辅助功能动作与普通界面动作仍走原 GUI 输入路径；CLI 显示不能伪造这些输入或改参数。

## 清理结果

正常完成或 CLI SIGINT/SIGTERM 会先熄灭 fresh 指示，再清理写过的显示目标；失鲜仍返回原非零结果。
窗口 source/config 变化使 endpoint 或旧 expected 失效，清理拒绝会保留 caller 的 `cleanup_failed`。
若 GUI 已接收 clear 但回执丢失，SDK 仍报告清理未证实，不自动重放该写入。
单纯截图/诊断写失败单独记录为 diagnostics，不冒称显示清理失败；真实清除、管道或 owned 目录清理
失败会在 final 记录与进程结果中可见。
