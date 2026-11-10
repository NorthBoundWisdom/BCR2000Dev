# 远程 Mac 实机测试准备

本工具包独立于 App，使用 Python 3.9+ 标准库及 macOS 14+ 系统框架。
包内 USB 描述读取器同时支持 Apple Silicon/Intel，不需远端安装 Xcode、pip 包或驱动。
它读取内核缓存的配置描述，不打开/独占/重置 USB 设备，不改配置或管道策略。
该物理读取分支仍待接回 BCR 后验证；没有设备时会明确报告未测试。

## 现场只需准备

1. 设备使用已备份的 Preset，USB 设 U-1；不刷固件或恢复出厂。
2. BCR 接回目标 Mac；若曾交给 Windows 虚拟机，先解除其 USB 接管。
3. 用同一 Mac 用户登录桌面，开启现有 SSH/远程控制，保持设备通电；若系统询问 USB 配件连接许可，现场先允许 BCR。
4. 暂停其他 MIDI/DAW 软件；不连接真实机械臂，App OSC 输出保持关闭。

届时提供 SSH 别名/地址即可，不在聊天中发送密码。测试开始后默认不需人工转旋钮。
灯环视觉验收与设备值回读分开，不用 API 成功代替硬件成功。

## 传输与完整性

把整个 ZIP 和 sha256 文件通过 SCP 送到目标 Mac，不只复制单个 Python 文件。
在目标 Mac 的终端/SSH 中：

```bash
shasum -a 256 BCR2000-Mac-Diagnostics-*.zip
# 与旁边的 .sha256 内容核对，再用 macOS 原生解压保留执行位：
mkdir -m 700 mac-diagnostic-session
ditto -x -k BCR2000-Mac-Diagnostics-*.zip mac-diagnostic-session
cd mac-diagnostic-session/BCR2000-Mac-Diagnostics
./Run-Mac-Diagnostics.command --mode preflight
```

入口会验证 manifest 内全部文件校验和，记录代码提交、系统和执行上下文。
如无 Python 3.9+ 或执行权限不足，会报错停止，不自动安装工具或更改安全设置。
报告默认在当前用户 Application Support/BCRAgentConsole/Diagnostics 的私有会话目录。
每次会话唯一，不覆盖旧报告；日志和原始控件值不进入仓库。

## 自动阶段

### 只读预检（默认）

- 原生 USB 服务匹配、缓存配置字节与 Full-Speed Bulk 包长检查。
- 与可选的 Windows USB 描述基线比对。
- CoreMIDI 端口、可用性元数据；属性缺失标为未知，不当作离线或在线。
- 传统包、MIDI 1 UMP、MIDI 2 下转换的虚拟设备身份、快照、五值写/读及恢复自检。
  自检仅接触本进程创建的虚拟目标，不向实体写 CC。
- 同时保存阶段退出码、超时、标准输出/错误和汇总 JSON。

已知的虚拟客户端创建 -304 可显式重试一次，两个尝试都会记录；不会重试实体写入。
其他自检失败阻止实机阶段，不静默换方式冒称通过。

### 只读实机矩阵

```bash
./Run-Mac-Diagnostics.command --mode matrix --baseline baselines/windows-usb.json
```

仅发送身份（01）/当前值快照（43）白名单查询，依次对照输入/输出和三种 API。
必须检测到恰好一台物理 BCR 和相应端口；无设备、端口歧义、无响应均不报通过。
默认最多 24 个组合，必要时用 --input/--output 缩小；全会话默认 240 秒期限。
收集最后五分钟与目标/包长/建管道相关的公开 USB/MIDI 日志；权限不足如实记录，不提权。

### 可选写入闭环

只有已有真实学到的普通绝对 CC 编码器，且设备身份/基线快照通过，才允许测试：

```bash
./Run-Mac-Diagnostics.command --mode matrix --baseline baselines/windows-usb.json \
    --target-profile private/target.local.json
```

私有目标文件只在显式打包时带入，未存 git；含实际通道/CC 及已验证身份。
没有目标参数的 matrix 始终不写 CC。默认完成后恢复基线值，--hold-max 才保留 127 并回读。
写入前先落盘基线；worker 超时/被强杀不保证恢复，报告会指出，且不会继续自动写第二条路由。
不执行预设选择、BCL/固件命令，也不修改硬件映射。

## SSH 与桌面会话对照

先直接运行预检。如果 SSH 的 CoreMIDI 可见性与桌面不同，可显式运行：

```bash
python3 macos_gui_session.py -- --mode preflight
python3 macos_gui_session.py -- --mode matrix --baseline baselines/windows-usb.json
```

此入口只向当前已登录用户的 GUI 域加载一个随机名称的临时任务，完成/超时后移除。
不会启用远程登录、重启 MIDIServer、增加持久登录项、更换用户或使用 sudo。
没有可访问的 GUI 登录时会报错，需先在现场登录一次。

## 决策与暂停点

- Windows 基线：USB 1.1 Full Speed、配置 101 字节，IN 0x81/64、OUT 0x02/4，一组 embedded MIDI 进出。
- 若 Mac 原始描述相同而逻辑端口不同，优先查 CoreMIDI 实体/驱动映射。
- 若描述不同，核对设备模式、枚举与缓存；不据此直接改硬件。
- 4-byte Bulk OUT 是兼容性嫌疑，不是已确诊的 Apple 故障；不混同合法的 4-byte MIDI event。
- 没有身份/快照回包，矩阵不会写 CC。发现只读错误先保留日志，不盲目改命令或重刷固件。
- 重启整机、切 MIDI 配置、独占 USB、调整 pipe、安装/替换驱动属于后续分立实验，准备工具不会自动执行。

## 打包与源码测试

在仓库 main 工作区：

```bash
python3 tools/package_macos_diagnostics.py --baseline build/windows-usb-descriptor-report.json
```

默认拒绝脏工作区；--allow-dirty 仅用于明确标记的开发包。
--target-profile 可加入本地私有目标，manifest 会标记；不复制 SSH 密钥、Keychain、环境文件或 App 配置。
构建使用现有 Swift SDK，warnings-as-errors，生成通用 ad-hoc 工具；不是发行版本，不创建 tag/release。

```bash
python3 -m unittest discover -s Tests/MacDiagnosticsTests -v
python3 tools/macos_bcr_selftest.py --mac-api legacy
python3 tools/macos_bcr_selftest.py --mac-api ump1
python3 tools/macos_bcr_selftest.py --mac-api ump2
```

## App 回归

独立 USB/MIDI 测试先执行，避免 App 与诊断进程相互干扰。App 使用单独构建的 universal ad-hoc ZIP，
兼容 macOS 14+ 的 ARM/Intel；本轮仅本机架构执行启动烟测，不冒称 Intel 运行验收。
App 的 Keychain/硬件映射属于目标 Mac 用户资料，不复制到公共工具包、不自动覆盖。
需要回归时先确认 OSC 仍关闭，MIDI 端口指向已验证的路由，再启动 GUI/MCP 流程。
诊断程序不要求启动 App，也不读取它的 Keychain 凭据。
