# DriverKit 正式分发申请模板

技术实验已通过。本模板不记录团队的具体授权关系、联系人或账号声明；这些内容由账号持有人审核填写。
开发签署成功不等于团队已经取得正式分发授权，Apple 的审核结果不能预先保证。

官方入口：[System Extension entitlement request](https://developer.apple.com/contact/request/system-extension/)。
申请需要在开发者账号内完成。由账号持有人/有相应权限的成员审核以下内容，选择既有付费团队。
不要勾选或声明团队拥有 Behringer 的 USB Vendor ID；不要代填尚未确认的厂商许可或合作关系。

## 技术字段

| 字段 | 内容 |
|---|---|
| 分发方式 | Developer ID，官网/GitHub Releases；不是开发设备限定分发 |
| 宿主 App ID | dev.bcragentconsole.descriptorprobe |
| DriverKit App ID | dev.bcragentconsole.descriptorprobe.driver |
| 当前实验所用 entitlement | com.apple.developer.driverkit；com.apple.developer.driverkit.transport.usb |
| 请求的硬件范围 | Behringer BCR2000，VID 0x1397、PID 0x00BC，bcdDevice 0x0100 |
| 已验证模式 | 固件 1.10、USB U-1；未声称其他模式/型号已验证 |
| 宿主 entitlement | com.apple.developer.system-extension.install |
| 不需要 | 自定义 user client、任意第三方 user client 访问、关闭 SIP、未签名 kext |

上述 bundle ID 沿用已验证实验的标识，正式包显示名为 BCR USB Compatibility。
如 Apple 要求改用其他最小权限或标识，先调整方案与验证，不伪造发行 profile。

## English draft for review

We are developing a macOS compatibility utility for the Behringer BCR2000
USB-MIDI controller.

[Account holder: accurately describe the relationship to Behringer / Music Tribe,
identify the actual owner of VID 0x1397, and state the scope of any confirmed
authorization. Do not claim to own the Vendor ID or represent the manufacturer
unless that is correct. Ask Apple whether additional authorization is required
for the described third-party compatibility use case.]

On the tested BCR2000 (firmware 1.10, USB U-1 mode, VID 0x1397 / PID 0x00BC,
bcdDevice 0x0100), its Full-Speed Bulk OUT endpoint 0x02 declares wMaxPacketSize=4.
The macOS USB host logs this as invalid and the OUT pipe lacks usable descriptors.
Device-to-host MIDI works, while host-to-device identity queries and CC feedback fail.

Our codeless DriverKit extension contains only an empty IOService subclass. Its
device-level matching personality uses Apple's AppleUSBMergeNub and
IOProviderMergeProperties approach documented in TN3190. It merges a host-side
configuration descriptor override changing only the Bulk OUT maximum packet size
from 4 to 8. Matching is restricted to the device identifiers above. It does not
replace Apple's MIDI driver, expose a custom user client, implement custom USB I/O,
modify firmware, or write controller presets. The companion application requests
normal system-extension activation/deactivation, and asks the user to reconnect
the device. No Recovery or reduced-security procedure is used.

With legitimately development-signed control and override builds on macOS 27.2,
we verified that the control personality merges its marker but does not restore
communications. The override build produces a valid Bulk OUT pipe with MPS 8,
device identity and snapshot replies, and five CC target values read back exactly.
The operator also confirmed the LED ring moves. The extension remains effective
after closing the host application and reconnecting the device, with SIP enabled.

We plan to distribute the companion application with our native BCR Agent Console
through GitHub Releases using Developer ID signing and Apple notarization. We
request guidance and the minimum distribution entitlements for this configuration.
The tested development build uses com.apple.developer.driverkit and
com.apple.developer.driverkit.transport.usb; we seek a restricted distribution grant
for the hardware above, rather than the development wildcard. Please also confirm
whether this codeless property-merge case needs USB transport permission or can use
a smaller supported entitlement set.

We can provide the minimal source and sanitized test results for review.

## 提交前仍需确认

- 账号团队及联系人由授权成员选择；本文件不记录密码、私钥、API key 或个人联系信息。
- 如实说明硬件关系及已确认的授权范围，不把技术可行性当作厂商许可或 Apple 批准。
- 审核并同意实际申请页的声明/条款后再提交；本轮没有进行提交或接受条款。
- 等 Apple 批准后，生成匹配宿主和驱动的 **Developer ID 分发 profiles**，不是当前开发 profiles。
- 正式发布前仍需在未注册的干净 Mac 验证从下载、授权到实机反馈的完整流程。

发布配置见 [TAG_RELEASE_SETUP.md](TAG_RELEASE_SETUP.md)。
