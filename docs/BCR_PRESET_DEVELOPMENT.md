# BCR2000 预设开发与兼容性

## 检查第三方预设

```sh
swift run --build-path build/swiftpm BCRProfileTool --inspect-preset /path/to/preset.bcl
swift run --build-path build/swiftpm BCRProfileTool --inspect-preset /path/to/preset.syx
```

工具也接受文本 `.bcr` 和 `.txt`。它读取本地文件，将 BCR2000 `$rev R1` 预设清单输出为 JSON。报告包含每个预设的编码器组数、CC／Note／NRPN 地址、已识别模式和数据位宽、`.minmax`、自定义发送所在行，以及同一预设内的重复地址。命令列表单独标出 `$store`、`$recall` 和 `$global`。行号从 1 开始，文本按文件行号，SysEx 按传输行号。预设名、自定义输出载荷和源文件内容不进入报告。

`$store` 会覆盖指定的设备存储槽。重复的 `.easypar` 地址也可能是预设作者有意设置的同步关系。工具仅提供离线清单，设备映射仍须通过 Quick Learn 或当前临时预设与设备快照核对。批量旋钮学习目前以四组、56 个身份唯一的普通绝对 CC 为边界。 [B-Control MIDI Implementation §§14.9、19](https://mountainutilities.eu/system/files/download/BC-MIDI-Implementation-1.2.9.pdf)

遇到设备拒绝或超时，预设对齐和恢复会显示传输行号、BCL 命令及此前已确认的行数。设备拒绝还显示原始错误码和已知含义。设备 ACK 是该行的传输证据，整次操作以完整回读为准。 [BCR2000_Master](https://github.com/christofmuc/BCR2000_Master) · [B-Control MIDI Implementation §21](https://mountainutilities.eu/system/files/download/BC-MIDI-Implementation-1.2.9.pdf)

## 编码器验收样本

| 样本 | 核对项目 |
| --- | --- |
| 普通绝对 CC | 下限、中点、上限、快照值及实体灯环 |
| Relative 1／2 | 顺逆方向、慢转步长、快转的多步增量、端点持续转动和绝对 LED 回写 |
| 七位 NRPN `absolute` | CC 99/98 选参数、CC 6 传值。现有 14 位解码路径要求 CC 38 |
| 十四位 NRPN `absolute/14` | CC 99/98/6/38、跨回调分段、交错消息、端值回写 |
| 四个实体编码器组 | 在非当前组回写已学旋钮，切回后分别核对快照及灯环 |

测试使用人工编写的最小规则。JX10 模板提供七位 NRPN 的实例。Matrix-1000 的生成器把参数表、物理布局和序列化分开，并对两种格式做逐字节回归。它的自定义 `.tx`、有符号参数及永久槽位适合检查预检报告。 [JX10 配置](https://github.com/withakay/JX10_BCR2000#setup) · [Matrix-1000 生成器](https://github.com/christofmuc/bcr2000_for_oberheim_matrix1000/blob/master/docs/generator.md) · [B-Control MIDI Implementation §§16.3–16.4](https://mountainutilities.eu/system/files/download/BC-MIDI-Implementation-1.2.9.pdf)

## 软件页、设备状态和固件资料

- Ableton 的八轨窗口可用现有 **页面与宏**实现同类布局。每页让相同的八个已学旋钮控制不同参数，并指定可返回基础页的导航键。切页时核对原页参数值、当前页的 LED 反馈和同一份 Quick Learn 映射。实体顶部编码器组是设备状态，现有 Port 1 实测见[启动数值回读与分组协议核对](HARDWARE_VALIDATION.md#启动数值回读与分组协议核对2026-11-12)。 [.egroups 协议 §13.4](https://mountainutilities.eu/system/files/download/BC-MIDI-Implementation-1.2.9.pdf) · [BCR2000plus](https://github.com/widdly/BCR2000plus)
- 对接有订阅期限的 OSC 设备时，在设备适配层续订状态通知，连接建立或状态失效后重新请求全量状态。用进程 epoch、序号和 I/O 接收单调时间核对新鲜度。本地 OSC 回环测试覆盖对端重启、旧 epoch 迟到、重复及倒序状态包，以及从新实际值重新使能。XR18 使用 `/xremote` 续订，是设备自己的协议。 [桥接实现](https://github.com/ClaudioGranatiero/OSC2MidiBridge/blob/master/Osc2MidiBridge.py#L562) · [本地 OSC 协议](OSC.md)
- 替代固件开发套件记录了启动流程、面板 I/O 及通过 DIN MIDI 使用救援模式的路径。排查 macOS USB 输出时，有同一原厂固件在主机端描述修复前后的测量可比对。 [TheKikGen/BCR2000-dev](https://github.com/TheKikGen/BCR2000-dev) · [原始开发套件](https://willem.engen.nl/projects/bc2000-dev/) · [本地 DriverKit 实测](DRIVERKIT_USB_PROOF.md)
