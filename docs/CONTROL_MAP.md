# BCR2000 控制器映射与反馈

## 为什么采用快速学习

BCR2000 的 CC/Note、通道、按键模式和 LED 行为由当前 Preset 决定。厂商手册确认它支持
software parameter feedback，但没有给出一个可安全假定为所有设备当前状态的固定
Preset 映射。因此 MVP 不把任何“常见默认 CC”写死，而是在 adapter 边界保存用户实机
发出的消息身份。

## 学习规则

- 接受 MIDI 1.0 UMP 中的 Control Change 和 Note On；
- CC 值 `64...127` 或 velocity 大于 `0` 被视为一次正向按下；
- 只有用户显式点击“开始 / 继续学习”时才会写入槽位映射；
- 切换到“硬件镜像”会暂停 Quick Learn，但仍继续记录实时 MIDI；
- 同一个 `kind + channel + number` 只能绑定一个槽位；
- 依次绑定 Agent 1–8；
- 正常运行时同一控件 250 ms 内只接受一次动作；
- 发送 feedback 后 180 ms 内的同值回环被抑制。

为了得到稳定的一次按下一次动作，建议把所选 BCR2000 按键设为 momentary，而不是
toggle。编码器会连续产生多条消息，不适合绑定首版的槽位主动作。

## 槽位动作

| 当前状态 | 实体按键动作 | 下一状态 |
|---|---|---|
| idle / completed / interrupted / error | 启动 Mock | queued |
| queued / running | 中断 | interrupted |
| waitingApproval | 批准 | running，随后 completed |

UI 按钮调用完全相同的入口，因此实体控制和软件控制不会形成两套状态。

## 状态反馈

软件向学到的同一 CC 或 Note 编号回写 7-bit 值：

| 状态 | 值 |
|---|---:|
| idle | 0 |
| queued | 40 |
| running | 127 |
| waitingApproval | 96 |
| completed | 72 |
| interrupted | 20 |
| error | 8 |

对 CC 映射发送 CC feedback；对 Note 映射发送 Note On，velocity 为上表值。具体呈现取决于
当前 BCR2000 Preset：它可能是按键灯、灯环段数或亮度。

## 端点策略

应用枚举显示名包含 `BCR2000` 的端点，并优先选择输入、输出两侧的 `Port 1`。CoreMIDI
setup change 会触发断开旧 source 后重新枚举和连接。当前 MVP 在 UI 中显示所有发现结果
和选择结果；手工选择多设备/其他端口留给后续版本。

## 本地映射

文件位置：

```text
~/Library/Application Support/BCRAgentConsole/controller-profile.json
```

此文件为本机设备状态，不进入 git。切换 Preset、重编控件或换设备后应在 UI 重置并重新
学习。

## 硬件镜像页面

“硬件镜像”是独立于 Agent 映射的实时 surface：

- 最多先展示 32 个 DAW 风格 encoder 位置，超过 32 个已发现 CC 时继续扩展；
- CC 按 `channel + number` 排序，空位不猜测 Preset；
- 每个旋钮分别显示最近设备输入 `IN`、软件回写 `OUT`、当前显示值和事件数；
- Note On/Off 以 button pad 显示；
- 页面切换不会停止 CoreMIDI，清空只清本次实时显示，不删除持久化 Agent 映射。
