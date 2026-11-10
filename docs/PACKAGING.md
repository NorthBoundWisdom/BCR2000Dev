# macOS 打包、签名与发布

构建参考 SonaFolio 的原生应用流程：应用版本配置、本机环境、SwiftPM 构建、`.app`
组装、签名、公证、DMG、构建记录，以及独立 runner 上的最终产物启动检查。
本仓库没有 FreeCM 子模块、依赖下载或 source-root lock。可选插件仅调用这些脚本。

## 环境与配置

需要 macOS、包含 Swift 6 的 Xcode 工具链和 Python 3.11+。
目标系统为 macOS 14+。主应用以 SwiftPM 为工程事实来源；DriverKit 配套工程在忽略目录生成，
不维护固定 `.xcodeproj`。

```bash
python3 configs/setup_local_project.py
```

`configs/app_build.json` 提供公开的 `MARKETING_VERSION`（三段数字）和 `ARCHIVE_ID`
（正整数）。`build.local.json` 被忽略，首次 setup 从 `configs/build.local.example.json`
复制；后续不覆盖。它的 `environment` 可放版本和签名环境变量，`path` 可放附加工具路径，
支持 `${REPO_ROOT}`、环境变量和 `~/`，不执行 shell。进程环境变量优先于本机配置。
成功 Config 后刷新被忽略的 `build/configured.json`，供插件判断配置新旧；本机配置保留原内容。

| 设置 | 用途 |
| --- | --- |
| `MARKETING_VERSION` | 覆盖应用版本及产物名称 |
| `ARCHIVE_ID` | 覆盖 CFBundleVersion 及产物名称 |
| `BCR_SIGNING_IDENTITY` | Keychain 内签名证书的完整名称或 SHA-1 |
| `BCR_NOTARY_KEYCHAIN_PROFILE` | `notarytool` 的 Keychain 凭证 profile 名称 |

证书、私钥、Apple 密码与 API 密钥不进入仓库；公证凭证存入 Keychain。
旧的本地 `source_roots.lock.jsonc` 不再被读取，可自行归档或删除。

## 构建和本地打包

```bash
python3 configs/macos_workflow.py build
python3 configs/macos_workflow.py run
python3 configs/macos_workflow.py test
python3 configs/macos_workflow.py package
python3 configs/macos_workflow.py package --architecture universal
```

`build` 默认 Debug，`--configuration release` 可构建 Release。`package` 始终构建 Release。
`--architecture` 支持 `native`（默认）、`arm64`、`x86_64`、`universal`。Universal 使用独立
SwiftPM 输出目录构建两个架构，再用 `lipo` 合并；所有架构均指定 macOS 14 部署目标。
`--format zip|dmg|both` 选择格式，默认两种。

应用生成于 `build/app/BCRAgentConsole.app`。图标从 `assets/AppIcon.png` 生成全部 macOS
iconset 尺寸，再转换为 ICNS 放入 Resources，并写入 Info.plist；应用启动时也会加载它
作为 Dock 图标。应用检查会验证签名、必要资源和动态库依赖；发现未部署的非系统动态库
会直接失败，未来增加此类依赖时必须先扩展部署流程。

默认 `--distribution ad-hoc` 不需要开发者账号。生成的本地安装包未经 Apple 公证；
正式网站分发应使用下述 Developer ID 流程。`--distribution development --identity ...`
可使用明确选择的 Apple Development 证书。多个匹配证书时脚本报错，要求指定唯一 SHA-1。

`build/package/` 中的每次打包输出：

- `BCRAgentConsole_v<版本>_<构建号>_macOS_<架构>_<签名方式>.dmg`；
- 同名 `.zip`，内含同一应用；
- 每个安装包对应 `.build.json`，记录版本、构建号、Git 提交、工作区是否有改动、架构、
  签名、公证状态、Swift 工具链和 SHA-256；
- 同名前缀 `.SHA256SUMS`，仅列出这次生成的安装包，避免混入历史版本。

DMG 是压缩只读镜像，内有 `.app` 和指向 `/Applications` 的快捷方式。安装时拖动应用
至 Applications。所有构建输出都被 Git 忽略。

## Developer ID 签名与公证

先在 Keychain 安装包含私钥的 Developer ID Application 证书，并创建凭证 profile：

```bash
security find-identity -v -p codesigning
xcrun notarytool store-credentials bcr-notary
```

第二条命令交互输入凭证；随后在本机配置填入证书名称/Profile，或通过 CLI 明确指定：

```bash
python3 configs/macos_workflow.py package \
  --architecture universal \
  --distribution developer-id \
  --identity 'Developer ID Application: Your Organization (TEAMID)' \
  --notary-profile bcr-notary
```

此流程启用 Hardened Runtime 和安全时间戳，提交临时 ZIP 公证，确认 `Accepted` 后给
`.app` staple ticket，再生成最终 ZIP/DMG；DMG 另外公证、staple。应用和镜像均检查 ticket，
并执行 Gatekeeper assessment。缺少 profile、证书歧义、公证失败或校验失败均返回非零，
不会降级为 ad-hoc 成功产物。普通 CI 和手动只构建任务维持 ad-hoc；显式版本 tag 使用下述正式签署流程。
本机打包仍可复用 Keychain；GitHub-hosted 正式发布需另行安全配置 Secrets，不自动导出本机私钥。

## 检查最终安装包

```bash
python3 configs/macos_workflow.py smoke
python3 configs/macos_workflow.py check-package \
  --archive build/package/BCRAgentConsole_v0.1.0_1_macOS_universal_ad-hoc.zip
python3 configs/macos_workflow.py check-package \
  --archive build/package/BCRAgentConsole_v0.1.0_1_macOS_universal_ad-hoc.dmg
```

`smoke` 要求图形登录会话，并等待原生窗口和第一帧，确认图标可读取后自动退出。
该模式使用临时空映射并禁用 MIDI 连接，不读写个人映射或向硬件发送消息。

`check-package` 要求对应 `.build.json`：先校验包哈希，再解压 ZIP 或挂载 DMG、将应用
复制至临时目录，检查签名、元数据、架构、系统动态库、公证状态和窗口启动；DMG 最后卸载。
若包的架构不含当前机器，则明确报告跳过启动，仅做结构检查。Universal 包可在两种机器上
运行启动检查。本机检查不替代 macOS 14 真机兼容性验证。

## GitHub Actions

- `ci.yml`：main push/PR 时检查插件清单、Python 工作流测试、Swift 测试、Debug 构建与启动。
- `release.yml`：手动输入版本可生成 Universal ZIP/DMG、记录和校验和，不发布 Release。
  显式推送 `v<major>.<minor>.<patch>` tag 时，使用正式签署、公证、DriverKit companion，
  同一流程验证通过后发布该 tag 的 GitHub Release；构建号采用 workflow run number。
- 打包后分别在新的 `macos-15`（ARM）和 `macos-15-intel` runner 上验证 ZIP 与 DMG。
  runner 没有构建目录，应用从临时安装目录运行。
- 最后验证所有记录的 Git commit、干净工作区、版本、架构及 SHA-256，再生成统一
  `SHA256SUMS`。缺件、混入旧包、记录或哈希不一致均阻止发布。
- 手动构建产物注明 ad-hoc、未经公证；版本 tag 强制 Developer ID、公证和获批 DriverKit 配套工具。
- 正式流程的凭证、profiles、双 App 包装与外部前置条件见 [TAG_RELEASE_SETUP.md](TAG_RELEASE_SETUP.md)。
  尚未配置完成时 tag 构建会失败，不发布开发签署或 ad-hoc 替代包。

仅配置上述流程不会创建 tag 或发布；发布动作由显式推送版本 tag 触发。

## FreeCM 插件接线与清理

```bash
python3 configs/validate_repo_commands.py .
python3 configs/source_root_workflow.py --init
python3 configs/source_root_workflow.py --update
python3 configs/source_root_workflow.py --cleanbuild --dry-run
python3 configs/source_root_workflow.py --cleanbuild
```

插件命令在 `configs/freecm.commands.jsonc` 中，包含 Config/Build/Run/Test/Package。
Package 默认 DMG + ZIP，保留原 `release-zip` ID，并新增 Developer ID 选项。
仅内置插件清单验证器的 MIT 源码快照，来源与许可证见 `configs/_vendor/`。
清理只删除明确列出的构建输出，不触碰运行数据、schema、本机配置或保留的历史 checkout。

参考：[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、
[GitHub runner 标签](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

## DriverKit 正式配套工具

默认构建不依赖 DriverKit。正式 tag 包增加独立的 BCRUSBCompatibility.app，
主应用继续保持 SwiftPM 构建；配套工具由生成于忽略目录的 Xcode 工程构建。
两个 App 都签署、公证并附加票据，最终 ZIP/DMG 同时包含它们。
`--driverkit-host` 只接受已获批、无开发调试权限的 universal Developer ID 配套工具；
校验 profiles、team、签章、范围、描述与版本后才打包。原实验开发包会被拒绝。

申请草稿见 [DRIVERKIT_DISTRIBUTION_REQUEST.md](DRIVERKIT_DISTRIBUTION_REQUEST.md)。
本轮没有提交申请、配置账号凭证或创建版本 tag。
