# Tag 自动正式发布准备

## 当前可用与外部前置

已具备本机 Developer ID Application 身份和已验证的 DriverKit 开发实现。
仓库目前没有发布 Secrets，也没有可用的 DriverKit Developer ID 分发 profiles。
技术代码可以准备完成；Apple 授权、账号声明和凭证传输需要账号持有人参与。
本轮没有导出私钥、创建 API key、上传 Secrets、提交 Apple 申请、创建 tag 或发布 Release。

申请模板及待确认字段见 [DRIVERKIT_DISTRIBUTION_REQUEST.md](DRIVERKIT_DISTRIBUTION_REQUEST.md)。
正式 USB entitlement 是否获批由 Apple 决定；当前预检会拒绝开发设备 profile、USB wildcard、
调试权限、过期、错误 team/bundle ID 或不同设备范围。

## 一次性配置

GitHub-hosted 方案需要在本仓库的 Actions Secrets 安全配置以下值：

| Secret | 内容 |
|---|---|
| BCR_SIGNING_P12_BASE64 | 只导出所选 Developer ID Application 身份及私钥，密码保护的 PKCS#12，再 base64 |
| BCR_SIGNING_P12_PASSWORD | 上述 PKCS#12 密码 |
| BCR_DRIVERKIT_HOST_PROFILE_BASE64 | 宿主精确 App ID 的 Developer ID 分发 profile，base64 |
| BCR_DRIVERKIT_PROFILE_BASE64 | 驱动精确 App ID、获批 USB 范围的 Developer ID 分发 profile，base64 |
| BCR_NOTARY_KEY_P8_BASE64 | 用户批准用于公证的 App Store Connect API 私钥，base64 |
| BCR_NOTARY_KEY_ID | API Key ID |
| BCR_NOTARY_ISSUER_ID | 团队 API key 的 Issuer ID |

不需要重新生成已有的 Developer ID 证书。不要导出整个 Keychain 或上传 Apple ID 登录密码。
本轮不会自行将 PCBAtlas 使用的私钥或凭证上传到新的仓库；需要明确批准其用途和目标。
也可另行采用专用受信任 Mac runner 的 Keychain 方案，避免把签署私钥传至 GitHub；尚未注册此 runner。

CI 只把显式提供的身份导入一次性 keychain，不导出本机身份。公证 API key 也必须由用户提供或另行授权创建。
签署命令的密码参数不打印；临时 keychain、文件和其搜索列表修改在 always 清理步骤撤回。

## 每次版本发布

只有明确推送 v<major>.<minor>.<patch> tag 才发布。tag 必须指向 main 历史中的提交；
构建号采用 workflow run number，在 App 与兼容工具间一致，用于后续扩展更新。

1. 运行 Swift/Python 检查。
2. 配置一次性 CI keychain，检查两个正式 profiles。
3. 使用正式、限定的 USB grant 编译签署通用兼容工具，驱动先于宿主签署。
4. 构建并签署通用控制台；ZIP/DMG 同时包含 BCRAgentConsole.app 和 BCRUSBCompatibility.app。
5. 两个 App 共同提交公证，Accepted 后分别附加票据；最终 DMG 另行签署、公证并附加票据。
6. 验证签章、profile、匹配范围、USB 描述、架构、Gatekeeper 与原生启动。
7. 在新的 ARM/Intel runner 验证 ZIP/DMG；兼容工具的 startup-smoke 不激活扩展、不访问 USB。
8. 验证 commit、干净工作区、版本、构建号、两种架构及 SHA-256，只发布验证清单中的文件。

缺凭证、审批范围不符、签署、公证或验收失败均停止，不回退成 ad-hoc 公开包。
workflow_dispatch 维持仅构建的 ad-hoc 路径，不访问发布私钥，也不发布 Release。
普通 CI 默认仍为 ad-hoc；FreeCM、主 App 的默认构建/运行方式不改变。

## 用户安装路径

下载正式 ZIP/DMG，将两个 App 放入 Applications。需要纯 USB 修复的用户打开
BCRUSBCompatibility，确认固件 1.10/USB U-1，再通过正常驱动扩展授权启用并重新连接 BCR。
不要求用户开发者账号、登记 UDID、Recovery 或降低 SIP。其他 USB 模式/固件仍须单独验证。
完整 R1 与跨机、到期、升级/卸载验收不因当前两旋钮实验通过而视为全部完成。

## 本机命令（授权及凭证准备好以后）

```bash
python3 configs/driverkit_release.py preflight \
  --host-profile build/private-signing/host.provisionprofile \
  --driver-profile build/private-signing/driver.provisionprofile
python3 configs/driverkit_release.py build \
  --host-profile build/private-signing/host.provisionprofile \
  --driver-profile build/private-signing/driver.provisionprofile \
  --identity "$BCR_SIGNING_IDENTITY" --version 1.2.3 --build-number 42
python3 configs/macos_workflow.py package --architecture universal --distribution developer-id \
  --driverkit-host build/driverkit-release/derived/Build/Products/Release/BCRDriverKitProbe.app
```

版本/构建号须通过 MARKETING_VERSION/ARCHIVE_ID 在两个构建步骤保持一致。
公证可复用已配置的 BCR_NOTARY_KEYCHAIN_PROFILE；CI 使用显式一次性 BCR_NOTARY_KEYCHAIN。
申请和凭证尚未完成时不要推版本 tag 来代替预检；可使用只读 preflight/check 检查缺件。

## 本轮验证与尚未执行

本机实际 Developer ID 主应用与 DMG 容器签署验证通过，没有导出私钥。
无签署的 ARM/Intel 配套工具编译及原生启动通过；双 App ZIP/DMG 佈局用隔离 fixture 实际验证。
默认 ad-hoc Universal ZIP/DMG 的解包/挂载和原生启动回归通过，工作流通过 actionlint。
204 条 Swift、42 条建置工作流 Python、28 条诊断 Python，以及两版隔离原生 MCP 验收通过。
当前已安装开发版的真实 profiles 被正式预检拒绝，缺失 CI Secrets 也按预期返回失败。

仍未以真实正式 DriverKit profiles 跑完整签署/公证，也没有创建版本 tag 或公开 Release。
需要 Apple 核准、授权配置凭证及干净未注册 Mac 的最终安装验证后，才可宣称正式分发就绪。

参考：[Apple 分发签署](https://developer.apple.com/forums/thread/809202)、
[Apple 自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
