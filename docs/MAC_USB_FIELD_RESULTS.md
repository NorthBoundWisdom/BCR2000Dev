# Mac 现场 USB 输出诊断（2026-11-10）

后续更新：已通过合法开发签署的 codeless dext，在保持 SIP 的情况下完成纯 USB 修复与现场灯环验收，
见 [DriverKit 实测](DRIVERKIT_USB_PROOF.md)。下文保留此前未找到替代路径时的实验记录。

## 实测结论

用户在硬件旁，通过 SSH 在其指定的另一台 Apple Silicon Mac 上执行；工作区为干净 main。
系统 macOS 27.2，Python 3.15.1，用户确认 Preset 8。
使用已校验 SHA-256/manifest 的 9665e52 独立工具包，不启动 App，不读取 Keychain 或覆盖映射。

- 真实设备的非独占缓存 USB 描述读取成功：VID:PID 1397:00BC、Full Speed、配置 1、101 字节。
  解析内容与成功 Windows 基线完全一致；IN 0x81/Bulk/64，OUT 0x02/Bulk/4。
- 当前 CoreMIDI 只有一组 BCR2000 输入/输出，与之前 Mac 的两入三出不同。
  因此此前的多端口现象不能单独解释本轮失败。
- legacy、UMP1、UMP2 的原生虚拟身份/快照/五值回读/恢复自检均通过。
- SSH 直接执行和当前用户 GUI 临时任务执行的实体查询矩阵均失败：三种 API 都没有身份回复，
  当前值快照计数均为 0；输入丢失数为 0，全部句柄关闭，GUI 临时任务已移除。
  矩阵按设计没有继续写 CC，没有把 API 接受视为设备成功。
- 用户实际转动一个带灯环的旋钮，独立输入监听收到同一普通绝对 CC 的连续值，硬件到 Mac 正常。
  实际 MIDI 身份只保存在忽略的私有报告中，不写入仓库。
- 按用户明确指令，向这个刚学到的同一旋钮发送 0/32/64/96/127，各停留 2 秒，最后发送恢复原值命令。
  用户全程观察并确认灯环完全没有变化。恢复仅为发送尝试，设备未回读确认，不宣称恢复成功。

## 内核证据

本轮公开 USB 日志明确记录：

```text
IOUSBHostFamily::validateEndpointMaxPacketSize: USB 2.0 5.[5-8].3: endpoint 0x02 invalid wMaxPacketSize 0x0004
```

此报错与实测 OUT 描述一致。它把主机 USB 输出管道列为当前首要原因；
独立工具同样失败，所以不能用 App 的渲染、SwiftUI 拖动或反馈调度解释本轮失败。
仍须经过针对性修复后的设备回读，才能完成本机因果验证。

## 已核对的针对性修复

[BCDescriptorFix 原项目](https://github.com/midiq/bcdriver) 作者报告：
在 BCR2000 固件 1.10/macOS 26.6.2 上，用 codeless kext 覆盖 OUT 包长为 8，
随后通过系统 USB-MIDI 驱动完成反馈和预设传输。这里是作者的实测声明，本项目尚未安装验证。

核对源码固定在提交 ef69fe7562b9119af0e007e59914ac2597ba9cff：
[Info.plist](https://github.com/midiq/bcdriver/blob/ef69fe7562b9119af0e007e59914ac2597ba9cff/Kext/BCDescriptorFix.kext/Contents/Info.plist)。
逐字节与本轮 Mac 读到的 101 字节配置比较，只有 offset 91（从 0 起）的 4 → 8 不同。
匹配限定 VID/PID 1397:00BC，通过 AppleUSBHostMergeProperties 覆盖主机描述，未改设备固件。
这是 wMaxPacketSize，不是合法的 4 字节 USB-MIDI event 数据格式。

原项目安装器还会检测、询问是否移动其他不兼容 kext，并使用 sudo 安装/加载扩展。
不把它作为普通诊断脚本自动执行，也不自动移动任何现有驱动。
目标机当前 SIP 完全启用；按原项目说明安装未获 Developer ID 签名的扩展，
需要用户在 Recovery 修改 kext 签名策略、授权安装并重启。这会改变主机安全设置，须另行明确决定。
本轮未执行安装器、未安装扩展、未降低 SIP、未独占 USB、未重启电脑或 MIDI 服务。
源码只下载到本地忽略的审查目录，没有纳入项目依赖。

## 后续实验与回退

选择描述覆盖实验前，现场用户需接受上述系统设置变化并预留 Recovery/重启时间。
保留原始描述、SIP 状态和本轮报告；明确记录扩展是否原已存在，不覆盖或移动其他驱动。
安装后重启并让 BCR 重新枚举，先重跑只读身份/快照，再对现场新学到的控件做五值写入/回读，
最后由现场观察灯环；以上通过才标记 USB 闭环修复，不靠安装器的日志检查代替验收。

若选择撤回，按原项目卸载本次扩展并重启；在 Recovery 恢复完整 SIP，重连后确认原生端点仍可用。
不愿改变系统安全设置时，可继续使用 Windows USB 路径；另一项独立方案是标准 USB-MIDI 接口加 DIN 线。
本轮没有证明普通更换 USB 线或 UMP 格式能够解决这个包长错误。

原始日志、完整设备值、旋钮学习记录与本地源码审查均在忽略的 build 目录，未纳入 git。
R1 的完整控件、NRPN、回显、重连和长时间测试仍未通过，见 [硬件验证](HARDWARE_VALIDATION.md)。

## 关于 sudo 与安全设置

用户随后要求先核对是否可以只用 sudo。本轮暂停扩展安装路径，确认目标机 SIP 仍启用，
BCDescriptorFix 未安装。普通管理员权限与内核扩展信任策略不同：
sudo 可以授权写入安装目录，却不能代替签名信任和启动安全策略。
[Apple 内核扩展安装说明](https://developer.apple.com/documentation/apple-silicon/installing-a-custom-kernel-extension)
要求 Apple Silicon 用户从 Recovery 允许第三方 kext；当前扩展还是未签名开发版本。
即使以后有 Developer ID 签名的 kext，也不应承诺在 Apple Silicon 上无需调整启动安全策略。

这不证明所有保持安全设置的 USB 方案都不可能。用户态 USB 兼容处理、Windows USB 桥接或虚拟机
是分立待验证方案，当前没有实现或实测，不能声称只加 sudo 就能成功。
本项目现阶段保留完整安全设置，不继续执行 Recovery、驱动安装或 USB 接管步骤。

## 保持安全设置的后续对照

用户要求继续尝试替代路径，本轮保持 SIP 完全启用，未安装扩展。

- 用户尝试将设备移到现有集线器路径；该连接下 USB 与 MIDI 均未枚举到设备，
  因此不能把它算作已完成的集线器输出测试。用户随后接回可识别的接口。
- 重连后设备位于另一根端口/控制器路径，配置描述仍为原始 101 字节、OUT 最大包长 4；
  只读身份/快照依旧无回复。
- 用 IORegistryEntrySetCFProperties 提交原始、未修改的配置描述，探测主机运行时覆盖能力。
  普通用户返回 kIOReturnUnsupported（0xe00002c7），覆盖属性没有出现；不是权限不足的返回码。
  SSH 的管理员授权未完成，不将其写成已经通过 root 实测。现场 sudo 对照仍需用户返回结果。
- 另写独立的 IOUSBHost 原生探针，在不提权、不强制接管的情况下短暂打开当前 BCR 的 MIDI Streaming 接口。
  IN 0x81 的原始和当前描述均存在，最大包长 64；OUT 0x02 虽有 Objective-C 对象返回，
  其 originalDescriptors/descriptors 实际均为 NULL。对象存在不能当作管道已经建好。
- 通过这个 OUT 对象直接发送标准 USB-MIDI 包装的只读身份查询，传输失败，字节数 0，
  错误 kIOReturnNotFound（0xe00002f0）。没有通过 CoreMIDI，也未向其他设备发送数据。
- 在同一短暂会话内尝试将这个 OUT 管道的主机策略设为包长 8，adjustPipe 同样返回
  kIOReturnNotFound；没有形成可用的替代管道。关闭接口后重开，再读配置仍为 4，未留下描述覆盖。
- 初版一次性原生探针直接解引用了 SDK 声明非空、实际为空的 OUT 描述指针，导致该探针进程退出 139。
  加入 NULL 检查后重新执行成功，保留前次失败，不把探针异常算作设备响应或系统崩溃。
  这是独立实验程序的问题，没有修改 App，也没有影响内核或预设。

原生探针均关闭接口并结束，没有驻留 USB 占用。最后 CoreMIDI 仍可列出一组 BCR 输入/输出，
USB 配置没有改变；未重启 MIDI 服务、整机或修改设备全局/预设设置。
本轮临时启动一小时限时 caffeinate 供远程测试使用，不改永久电源设置。

另核对了 [Apple 开源 XNU 的 IOCatalogueSendData 实现](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOUserClient.cpp)：
驱动 personality 注入还要求专用 catalogue management entitlement；没有该资格时甚至可能返回伪成功。
因此不将普通 sudo 调用该接口包装成已验证修复，也没有尝试注入或伪造 entitlement。

本轮仍没有找到保持完整安全设置的本机直连修复。后续可分开验证的路径是：
有现成环境时测试 Windows 虚拟机 USB 接管，或设备接回 Windows 后实现 MIDI 网络桥接。
目标 Mac 当前未发现 Parallels/VMware/UTM/VirtualBox 应用，未安装新虚拟机或软件；
这两项均未实测，不要求用户现在购买线材或许可证。
