# R1 实机验证记录

本次在 main 工作区开始实机验证；记录已观察事实，不以 Mock 测试代替实测。

## 已确认

- 用户报告硬件当前 Preset 为 8；USB 模式、固件版本尚未确认。
- CoreMIDI 输入：BCR2000 Port 1、Port 2；输出：Port 1、Port 2、Port 3。
- 只读探针创建 MIDI Client、创建输入端口、连接 Port 1 均返回 OSStatus 0。
- 本次冷启动最新版 App 显示 BCR2000 Port 1 在线；未观察到 -304。
  这不是对重开/热插拔可靠性的完整结论。
- 目前实体映射为空，未将 Mock 的 CC1–108 预设套用到硬件。
- 在备份/学习前 App 保持 Mock，实体输入仅记录；OSC 输出关闭。

## 接下来的操作

1. 接收当前 Preset 的 Single Preset Dump：硬件按住 EDIT 再按 PRESET ►。
   只读接收器不打开 MIDI 输出端口，文件保存在本机 Application Support/Backups，不进 git。
2. 备份接收并验证完整帧后，切换实体模式，从 P1-1 开始显式学习。
3. 用户每次只操作提示的控件；记录软件学到的身份，并通过同一身份验证反馈。
4. 对照 TODO HW0–HW6 逐项推进；相对编码、NRPN、回显、非当前组 LED 均保留待实测标记。

备份的收帧完整性与真实恢复可用性是不同检查；本轮不向硬件发送备份或 SysEx。
不改写 Preset、不恢复出厂、不连接真实机械臂。
