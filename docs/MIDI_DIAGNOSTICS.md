# 无第三方依赖的 MIDI 回写诊断

`tools/midi_feedback_probe.py` 使用 Python 标准库：Windows 调用 WinMM，macOS 调用 CoreMIDI。
它独立于 Swift App，用于对照主机的 MIDI 输入与反馈路径。不需要 pip，也不发送 SysEx 或保存/覆盖硬件预设。

## 同一个控件自动学习

在测试前关闭其他 MIDI 应用，使用同一 Preset、同一个编码器组和同一个**绝对 7-bit CC 编码器**。
不用提供 Preset 编号或猜测 CC：脚本从实际输入学习通道、编号和最后数值。
按钮、相对编码、NRPN/RPN、Bank Select、Channel Mode 不适合此测试；检测到相关保留控制器或多个 CC 时拒绝发送。

Windows：

```powershell
py -3 tools/midi_feedback_probe.py --mode list
py -3 tools/midi_feedback_probe.py --mode test
```

macOS：

```bash
python3 tools/midi_feedback_probe.py --mode list
python3 tools/midi_feedback_probe.py --mode test
```

转一个旋钮后停手。脚本等输入停止一秒，再等两秒，依次发 `0、32、64、96、127`，
每值停留 1.5 秒，最后尝试发送恢复值。测试时不要再转动旋钮。
`TX` 只证明原生 API 接受消息；必须看到**同一个灯环**跟随五个位置才能认为硬件回写通过。
退出/取消时也尽力恢复最后观察值，进程强杀、掉电或发送故障不保证设备恢复。

有多个端口时，依据本次打印的编号明确指定：

```bash
python3 tools/midi_feedback_probe.py --mode test --input 0 --output 0 --seconds 120
```

默认优先名称唯一的 BCR2000 Port 1，或名称唯一的 BCR2000；默认拒绝非 BCR2000 输出。通过 DIN/网络接口连接时，必须明确指定两个端口并加 --allow-other-device，避免把消息自动送到其他设备。
脚本的端口索引在重插/换机后可能变化；App 端口设置则保存 CoreMIDI UniqueID。
只读监听使用 `--mode monitor --input 0 --seconds 30`；默认 `--mode list` 不打开输出。

## macOS 自动验证与对照

下列自检仅创建虚拟输入/输出，不发送给实体设备：

```bash
python3 tools/midi_feedback_probe.py --self-test
python3 tools/midi_feedback_probe.py --self-test --mac-api ump1
python3 tools/midi_feedback_probe.py --self-test --mac-api ump2
python3 tools/midi_feedback_probe.py --self-test --mac-api ump2 --packet-repeats 16
python3 -m unittest discover -s Tests/MIDIFeedbackProbeTests -v
```

`--mac-api legacy/ump1/ump2` 分别对照传统 MIDI 1 数据包、协议化 MIDI 1 UMP、MIDI 2 CC 经 CoreMIDI 转换到 MIDI 1。
`--packet-repeats 1..16` 在一个原生包中重复同一 CC，用于短包传输的受控对照；默认 1。
这些选项只在 macOS 使用，不是已证实的驱动修复。

回调只复制数据并交给有界队列；不在驱动回调内调用 WinMM、等待、打印或发送。
macOS 按当前 SDK 的 ARM 四字节对齐规则遍历可变长包；Windows 使用固定宽度 ABI 类型，
输入/输出能力结构分别为 76/84 字节，保留回调对象直到句柄关闭。

本轮已运行离线测试及 Mac 原生虚拟回环。Windows 原生 Python 后端尚待 Windows 实机确认；
用户此前在 Windows 通过的是独立 PowerShell/WinMM 脚本，不混作本脚本的实机验收。

原生接口依据 [Microsoft WinMM MIDI 文档](https://learn.microsoft.com/en-us/windows/win32/multimedia/sending-individual-midi-messages)
和 [Apple CoreMIDI](https://developer.apple.com/documentation/coremidi)；实际诊断结果见 [R1 记录](HARDWARE_VALIDATION.md)。

## 线缆和虚拟机的后续路线

优先做完整 Mac 重启后的同脚本对照，暂不要求购买设备。本轮只重启了 MIDI 服务和 BCR，
没有自动重启整台电脑。Windows 成功、Mac 独立脚本失败把范围缩到本机 USB-MIDI 路径，尚未证明具体驱动缺陷。

- 虚拟机可用于对照：USB 设备交给 Windows 独占。Apple Silicon 上使用 ARM Windows，
  需要兼容 ARM64 的设备驱动；支持 USB 直通不等于驱动必然可用。
  USB 交给客体后，Mac App 不能同时直连，正式使用还需桥接方案。
  参考 [Parallels 的驱动兼容说明](https://www.parallels.com/products/desktop/microsoft-authorized-solution-windows-11-arm/)。
- 绕过 BCR 自带 USB 的硬件路线：选择厂商明确支持当前 macOS/Apple Silicon 的 USB-MIDI 一入一出接口，
  接口 OUT → BCR MIDI IN，BCR OUT A → 接口 IN，使用两条标准五针 DIN MIDI 线
  （接口自带两条 DIN 插头线时无需另外买）。BCR 设 S-4，仍用其正常电源。
  App 中手动选择该接口的输入/输出。它是后续对照路线，未在本机实测，不承诺一定解决。
  接法依据 [Apple 的 MIDI 接口说明](https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp13f602e3.html)
  和 [BCR 用户手册 S-4/参数反馈](https://mediadl.musictribe.com/media/PLM/data/docs/P0245/BCF2000_BCR2000_M_EN.pdf)。

建议先借到接口验证，再决定购买；不要将只有单向转换或不支持当前系统的线当作双向反馈方案。

## Windows 无人值守回读

新增 `windows_bcr_roundtrip.py` 使用设备只读身份和当前值快照命令，无需人工按 Snapshot 键。
它与普通五段扫描工具不同：会发送两种白名单只读 SysEx 查询，但不发送预设/BCL/固件命令。
默认只读：

```powershell
py -3 tools/windows_bcr_roundtrip.py --report readonly-report.json
py -3 tools/windows_usb_descriptor.py --report usb-report.json
```

写入测试必须明确填写此前学到的编码器 `--test-cc` 和 `--channel`，且先验证设备身份与快照。
不要猜控制器编号。`--hold-max` 会保留 127，否则尽力恢复基线值；两种情况下均再请求快照核对。
一个单独回显不算快照；目标缺失、同身份冲突、输入溢出时不报通过。

本轮已在用户提供的 Windows 测试机经 SSH 实测：身份、56 条 CC 快照、五值写入与回读全部通过，
最终设备回读为 127。未远程观察 LED 外观。完整硬件与 USB 描述基线见
[Windows USB 基线](WINDOWS_USB_BASELINE.md)。
