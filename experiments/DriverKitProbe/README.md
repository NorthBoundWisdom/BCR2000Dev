# BCR2000 DriverKit 描述覆盖可行性验证

这是独立实验，不是 BCR Agent Console 的构建依赖或发行驱动。
保持 SIP 与启动安全策略，通过合法开发签署、正常系统扩展授权验证 codeless dext 的作用时序。
驱动只有空 IOService 子类，不实现 MIDI 协议、用户客户端、Start/Stop 或 USB I/O。

## 假说与对照

采用 [Apple TN3190](https://developer.apple.com/documentation/technotes/tn3190-usb-audio-device-design-considerations)
的设备级 AppleUSBMergeNub / IOProviderMergeProperties 配置，而不是改名重装未签名 kext。
匹配限定 VID 1397、PID 00BC、bcdDevice 0100；不匹配其他硬件。

- control，版本 1：只合并 BCRDescriptorProbeVersion 标记。
- override，版本 2：标记加 kUSBDescriptorOverride，使用本机实际读取的配置，只把 Bulk OUT 0x02 包长 4 改为 8。
- 使用相同 bundle identifier，依次替换，不同时安装两套 personality。
- 属性覆盖键被系统消费后可能不再出现在 IORegistry；不能用键缺失判定失败。
  也不能只用扩展已启用、对象非空或 API 成功判定修复。

验收顺序：合法签署及正常授权 → 重枚举后的标记 → 实际 OUT 管道有效 → 身份与快照回复 → 五值回读 → 灯环。
实际结果见 [验证记录](../../docs/DRIVERKIT_USB_PROOF.md)。

## 准备与编译

需要已安装的 Xcode / DriverKit SDK，不安装第三方依赖。输入是忽略目录中、覆盖前的只读 USB 报告：

```bash
python3 tools/driverkit_probe.py preflight
python3 tools/driverkit_probe.py build --usb-report build/original-usb-report.json
python3 tools/driverkit_xcode_project.py --team "$BCR_DEVELOPMENT_TEAM" --variant control
xcodebuild -project build/driverkit-probe/xcode-control/BCRDriverKitProbe.xcodeproj \
  -scheme BCRDriverKitProbe -configuration Debug -derivedDataPath build/driverkit-derived \
  -allowProvisioningUpdates build
```

第一条只读查询身份和 profile，只输出摘要，不导出私钥或完整 profile。
沙箱可能限制 Keychain/CMS/系统服务，查询失败或零结果不能直接当作账户没有证书。
build 只生成未作部署签署的通用候选，不签署、安装、加载或修改安全设置；manifest 明确 hardwareTested=false。
IIG 即使返回 0 也可能生成空文件，脚本检查非空类定义与编译诊断。
项目、捕获的 USB 描述、签署包和 profiles 均保留在忽略的 build 目录，不提交。

## 开发签署边界

[Apple DTS 的新流程](https://developer.apple.com/forums/thread/809202)说明，付费团队可通过 Xcode
自动签署取得开发用 DriverKit USB 授权；USB 开发配置使用 idVendor="*"。
这里的 wildcard 仅为开发签署授权，硬件匹配条件仍限定在上述 BCR；不是发佈授权。
不要把 development grant 改名当作分发授权，也不走关闭 SIP 的旧调试流程。

在 Apple Silicon 上验证开发 profile 是否涵盖本机时，要用 Provisioning UDID，不能用 Hardware UUID。
签署成功还必须验证嵌入 profile、签章、bundle identifier 与实际目标，才能进行加载实验。
普通系统扩展授权可能需要在「系统设置 → 通用 → 登录项与扩展 → 驱动程序扩展」开启开关。

ProbeHost 默认只显示按钮，不自动加载；显式 --activate/--deactivate 可用于已授权的自动测试。
--report 后指定私有 JSON 路径，记录等待授权、失败和系统请求结果；不将系统结果标记成硬件通过。
缺少嵌入 profile 时不提交激活请求。此宿主不访问 MIDI、OSC、App 配置或 Keychain 令牌。

## 重新枚举与回退

加载之前就已连接的设备，需要重新枚举才能测试新的配对时序。可手动拔插，或明确执行：

```bash
swiftc -swift-version 6 -warnings-as-errors experiments/DriverKitProbe/Reenumerate.swift \
  -o build/bcr-reenumerate
build/bcr-reenumerate --self-test
build/bcr-reenumerate --reenumerate
```

无参数不会访问 USB。脚本只允许恰好一台指定 BCR，普通打开失败即停止，不强制接管、不操作其他设备。
重新枚举相当于软件拔插，不发送固件、预设或 MIDI 写入命令；不把 API 成功当作重新配对成功。

回退时，用宿主的「移除测试扩展」或显式 --deactivate 正常注销，确认完成后重新枚举 BCR。
保留签署宿主和实验记录直到回退验证完成；不删除其他扩展或 profiles。
本轮没有更改安全策略，因此不需要通过 Recovery 恢复 SIP。

正式分发仍需产品化安装/卸载、限定 USB 发布授权、分发签署与公证，以及不同机器/系统版本的验证。
开发 profile 有效期与设备清单受限，不能作为面向所有用户的长期发行方案。
