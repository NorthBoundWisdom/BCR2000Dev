# Windows SSH 无人值守 USB 基线

测试对象是用户此前在 Windows 观察到灯环五段变化的同一台 BCR2000。
本轮通过现有 SSH 金钥连接；未要求现场人员转动旋钮或观察灯环，未安装驱动或第三方包。

## 已实测

- Windows x64、Python 3.12，SSH 进程位于 Session 0，WinMM 可以直接访问这台设备。
- MIDI 输入为 BCR2000，输出明确选择 BCR2000；没有向 Microsoft GS 输出。
- 原生 Windows 媒体驱动服务为 usbaudio，INF 为 wdma_usb.inf，版本 10.0.26100.9818。
  不依赖额外 Behringer 驱动。
- 只读身份查询获得 BCR2000 1.10；只读当前值快照获得 56 条 CC 数据。
- 对此前真实学到的一个普通绝对 CC，分别写 0、32、64、96、127；每次随后请求快照，
  五次设备回报都与请求一致，输入丢失数为 0。
- 每次写入后、请求快照前观察 250 ms，未收到目标 CC 的自动回显。
  这是此 Windows/U-1/预设组合的测量，不扩大为所有系统与模式的结论。
- 最后保留最大值 127，并再次从设备快照确认 127。
- 本轮没有观察 LED 光学显示；内部值闭环与视觉验收分开记录。

## USB 描述基线

通过 Windows USB hub 的标准 GET 查询读取，没有发送 MIDI 数据、修改配置或复位设备：

- USB 1.1、Full Speed；VID:PID 为 1397:00BC。
- 当前配置 1，配置描述共 101 字节。
- MIDI Streaming 介面 1，alternate 0，class 1/subclass 3/protocol 0。
- USB IN 为 0x81、Bulk、最大包长 64；USB OUT 为 0x02、Bulk、最大包长 4。
- 两个方向各关联一个 embedded MIDI jack，符合 Windows 枚举的一组输入/输出。

Mac 先前 CoreMIDI 列出两入三出，与这一基线不同。需要设备接回 Mac 后读取同一原始描述，
才能区分旧实体缓存、描述解析或管道初始化差异；目前不能直接认定缓存就是原因。

## 更具体的兼容性嫌疑

Full-Speed Bulk OUT 宣告最大包长 4，是需要重点核对的异常点。
注意这指 wMaxPacketSize，不是合法的 4 字节 USB-MIDI Event Packet 本身。
Linux 曾针对**另一款设备**的同类 4-byte 宣告导致 xHCI Parameter Error，
通过在主机端将包长归一到至少 8 修复，见
[Linux 上游提交 f148b9f](https://github.com/torvalds/linux/commit/f148b9f402ef002b57bcff3964d45abc8ffb6c3f)。

这支持主机 USB 管道兼容性假说，但不是对本机 Apple 驱动的因果证明。
下一步在 Mac 读原始描述与管道错误，再考虑主机端兼容处理。
本轮没有修改设备描述、固件、MIDI 设置或驱动，也没有宣称 Mac USB 问题已经修复。

## 可重复工具

- tools/windows_bcr_roundtrip.py：默认只发身份（01）和当前值快照（43）只读请求；
  其他 SysEx 命令拒绝构造。只有显式指定已知编码器 --test-cc 时才写普通 CC，
  且须先验证身份和无冲突的基线快照；默认恢复原值，--hold-max 留在 127。
- tools/windows_usb_descriptor.py：只读 BCR USB 配置描述，拒绝截断描述，并标出 Full-Speed Bulk 包长异常。

原始设备值与报告位于本机/远端临时诊断目录，不进入 git。

协议来源：[BC MIDI Implementation §6.1/§23.4](https://mountainutilities.eu/system/files/download/BC-MIDI-Implementation-1.2.9.pdf)；
USB GET 查询依据 [Microsoft USBView 示例](https://github.com/microsoft/Windows-driver-samples/tree/main/usb/usbview)。
