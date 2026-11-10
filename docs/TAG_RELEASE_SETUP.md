# Tag 发布：无需凭证的常规构建

## 当前策略

按当前自用阶段的选择，普通 main/PR CI、手动构建与版本 tag CI 都固定为 ad-hoc。
不读取 Apple 证书、私钥、profiles、公证凭证或任何 Actions Secrets；
不导入 Keychain、不运行 DriverKit 发布构建，不进行 Apple 公证。
没有 repository variable 或环境开关可把这些 CI 自动切换为需要凭证的模式。

发布资产所需权限仅为 GitHub 自带 GITHUB_TOKEN；不要求另行配置 token 或签署 Secrets。
未创建版本 tag、未提交 Apple 授权申请、未导出/上传签署私钥。

## 版本 tag 会做什么

推送如 `v1.2.3` 的版本 tag，且 tag 指向本次更新或之后的 main 提交后：

1. 校验版本，采用 workflow run number 作为构建号。
2. 运行 Swift/Python 测试与两版隔离原生 MCP 验收。
3. 常规编译 ARM/Intel 通用主程序，固定使用 ad-hoc 签名。
4. 生成 ZIP/DMG、构建记录和校验和。
5. 在新的 ARM/Intel runner 解包/挂载并验证原生启动。
6. 校验源码 commit、版本、架构与 SHA-256。
7. 从已验证的资产清单创建该 tag 的 GitHub Release，说明明确标注 ad-hoc、未公证。

无需签署证书或公证配置；检查失败不会发布。
workflow_dispatch 走相同的无凭证构建/验收，只上传 Actions artifacts，跳过 publish。
普通 main/PR CI 编译并运行测试、原生启动及 MCP 验收，不创建 Release。

只配置流程不会创建 tag。需要发布时由用户明确推送版本 tag。

## 包含什么

当前下载包只有 BCRAgentConsole.app，不包含 DriverKit 配套 App/dext。
普通控制台可用 Mock，或通过兼容的 MIDI 端点工作。
如果该 Mac 已独立安装开发签署的 USB 修复，可以继续沿用；新 Mac 不能靠此 ad-hoc 包自动获得 USB 修复。

DriverKit 修复与控制台目前分开。将来即使合并打包，扩展仍需要 Apple 认可的签署/profile。
自用可以使用已登记设备的开发签署；面向任意未登记 Mac 的完整版需要正式 DriverKit USB
分发授权、Developer ID 签署及公证。当前不申请，也不在 CI 导入其凭证。

## 保留但未启用的预备工具

configs/ci_signing.py 和 configs/driverkit_release.py 是将来显式配置的预备工具，
当前 workflows 不调用。正式授权申请模板见 [申请模板](DRIVERKIT_DISTRIBUTION_REQUEST.md)，
本机签署方式见 [打包说明](PACKAGING.md)。重新启用须明确修改工作流和准备相应授权/凭证，
不能把开发包或 ad-hoc 包标为不受设备限制的 DriverKit 正式发行版。
