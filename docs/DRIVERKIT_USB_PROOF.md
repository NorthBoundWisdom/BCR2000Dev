# DriverKit 纯 USB 验证结果（2026-11-10）

## 结论

在当前 Apple Silicon Mac/macOS 27.2、同一 BCR2000 固件 1.10 上，
通过合法签署的 codeless dext 合并主机描述属性，已恢复纯 USB 双向通讯。
全程 SIP 保持 enabled，没有进入 Recovery、降低启动安全策略、安装 kext 或修改设备固件/预设。
用户现场确认顶部左侧灯环随写入变化。

这是当前设备上的可行性验证，不等同于所有系统/设备的兼容验证或正式发行。

## 实验依据

- [Apple codeless dext 说明](https://developer.apple.com/documentation/systemextensions/implementing-drivers-system-extensions-and-kexts)：
  最小驱动仍包含空子类的二进制，不能只有 plist。
- [TN3190](https://developer.apple.com/documentation/technotes/tn3190-usb-audio-device-design-considerations)：
  官方设备级 AppleUSBMergeNub personality 合并 IOProviderMergeProperties 的范例。
- [Apple DTS 开发签署流程](https://developer.apple.com/forums/thread/809202)：
  付费团队可自动取得开发用途的 USB entitlement，不把旧的关闭 SIP 调试流程作为本次前提。

这些资料给出构建和属性合并的依据；是否能修复 BCR 描述，在本轮实机实验中单独验证。

## 对照与证据

| 阶段 | 结果 |
|---|---|
| control v1 | 只合并标记，正常系统授权后 activated enabled |
| control 重新枚举 | registry ID 更新，设备节点出现 control-v1 标记 |
| control 身份/快照 | 无身份回复、0 条快照、没有写 CC |
| override v2 | 同一 bundle ID 正常替换，activated enabled |
| override 重新枚举 | registry ID 更新，设备标记 override-v1 |
| 配置比较 | 101 字节只有 offset 91 的 4 → 8 不同 |
| 原生 OUT 管道 | 原始/当前描述有效，MPS 8；原生只读身份写出 12 字节，收到回复 |
| CoreMIDI 身份/快照 | BCR2000 1.10，56 条 CC，输入丢失 0 |
| 首个已学旋钮五值闭环 | 请求 0/32/64/96/127，设备逐次回读相同值；最终再次确认 127 |
| 顶部左侧已学旋钮 | legacy、UMP1、UMP2 三种 API 的五值回读均一致，最终 127 |
| 视觉验收 | 用户现场确认顶部左侧灯环确实变化 |
| 关闭宿主后重连 | 软件重新枚举后身份仍回复；两个已学旋钮均读回 127、零输入丢失 |

原生探针收到身份回复后继续读直到有界超时，最终一次空读超时是停止条件，未当作新的设备错误。
修复前，同一 OUT 对象无有效描述，原生写入为 0 字节并返回 NotFound；修复后已是实际数据回复。
完整 SysEx、设备值、实际控制器身份和捕获文件仅在忽略的本地 build 报告中，不提交。

系统可能消费并移除 kUSBDescriptorOverride 属性：本次 marker 已在，覆盖键不再列出，
但缓存配置已经是 8，实际管道和身份/回读也通过。因此不会用覆盖键的存在与否替代功能验收。

## 签署与安装

- 使用现有付费团队的 Xcode 自动开发签署；签章与嵌入 profile 校验通过。
- 检查本机 Provisioning UDID 是否在 profile 内；初次误用 Hardware UUID 的预检在复制之前停止，
  修正检查后才安装，未绕过装置授权。
- 用户正常开启驱动扩展开关，不是放宽系统启动策略。
- 安装于独立的 BCRDriverKitProbe.app，不修改生产 App 或其构建/包装配置。
- 空 DriverKit 子类不重写 MIDI；既有 Apple USB-MIDI/CoreMIDI 路径继续处理协议。
- 主机描述覆盖发生在重新配对流程，未用 AdjustPipe 修补已失败的 Bulk OUT。

实验代码、构建方式和回退说明见 [DriverKitProbe](../experiments/DriverKitProbe/README.md)。
开发 profile 需要续签，发布授权与正式分发尚未完成；不要将当前包作为普通用户发行版。

本轮最终源码的 ARM/Intel 宿主与 dext 签署构建成功，无编译警告；204 条 Swift、
28 条建置工作流测试、DriverKit/诊断 Python 测试、两个版本的隔离原生 MCP 验收通过。
重新枚举工具另有不访问 USB 的目标选择自测。

测试宿主和 MIDI 测试进程已退出，实验扩展继续启用；两个已验证旋钮留在 127 供现场验收。

## 验收范围

已验证当前 Mac 的基础纯 USB 反馈闭环和现场灯环；不据此勾选全部 R1。
108 控件学习、Relative/NRPN、非当前组、休眠/重连、长期稳定性仍须逐项测试。
后续不需要为这条实验路径修改恢复模式或 SIP。

## 开发签署维护（2026-11-11 更新）

按用户授权，使用 PCBAtlas 已配置的开发团队及本机有效 Apple Development 身份，
通过 Xcode 自动签署取得并安装开发 profile。没有新建或导出私钥。
control 变体的宿主与 dext 构建成功，`codesign --verify --deep --strict` 通过；嵌入 profile 的授权检查通过。
这些是开发签署结果，不作为 USB 功能或扩展激活结果。

| profile | UTC 到期日 | 已检查授权 |
| --- | --- | --- |
| 开发宿主 | 2027-11-11 07:43:21 | system-extension.install |
| 开发 dext | 2027-05-15 08:51:06 | driverkit、USB 开发 wildcard、get-task-allow |

凭据、profile 和生成的工程/签署产物只在本机 Xcode 快取与忽略的 `build/driverkit-signing/`，不提交。
驱动到期日较早，应在该日期之前重新运行自动签署并检查新的到期日。

macOS 升级、重装或换机器后的复核顺序：

1. 使用 `python3 tools/driverkit_probe.py preflight` 检查开发身份、profile 授权与本机 Provisioning UDID。
2. 按 DriverKitProbe README 重新生成本地工程并允许 Xcode 更新开发 provisioning；检查宿主与 dext 的嵌入
   profile 到期日、bundle identity、设备覆盖及开发 USB 授权，然后运行 codesign 深度严格校验。
3. 需要恢复已实测的描述覆盖时，必须使用该设备的原始只读 USB 报告重新构建 override 变体；
   本轮 control 签署产物只用于签署验证，不能替代 override 功能验证。
4. 通过正常系统扩展流程安装/授权，并核对启用状态与重新枚举后的 BCR 标记；保持 SIP 与启动安全策略。
5. 显式选择 BCR Port 1，只读查询身份与完整快照；与原基线比较。快照缺失时停止后续写入测试。
6. 在已学普通绝对 CC 控件上完成 0/32/64/96/127 五值回读，并按工具的恢复逻辑还原原值；
   人工检查灯环以及重新连接后的身份/快照。仅签署通过不能勾选此步。
7. 将结果记录为新系统/设备的一次实测；失效时标明 R1 阻塞，不沿用旧系统的通过结论。
