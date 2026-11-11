# 原生 UI 验收

这些脚本验证当前 SwiftUI 界面的完整交互，保留作为人工发布前或相关 UI 改动后的验收入口。
无需实体 BCR2000；它们不是无界面的单元测试，也不代替 [R1 实机验证](HARDWARE_VALIDATION.md)。

## 运行方式

先在仓库根目录构建 Debug App：

```bash
python3 configs/macos_workflow.py build
```

在已登录且解锁的 macOS 图形会话中，逐个运行下面的命令。启动命令的终端 / Agent 宿主需要
“系统设置 → 隐私与安全性 → 辅助功能”权限；截图还需要屏幕录制权限。
不并行运行，以免共享 MCP 端口或键盘焦点相互干扰。

```bash
python3 tools/mcp_integration.py --configuration-write --script tools/verify_configuration_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_endpoint_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_functions_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_output_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_precision_ui.py
python3 tools/mcp_integration.py --configuration-write --script tools/verify_review_fixes_ui.py
```

`mcp_integration.py` 为每次运行复制一个有唯一进程身份的 App，使用临时配置、内存凭据与
Mock 机械臂示例预置，不读取生产配置或 Keychain，不启动实体 MIDI。
每次先在运行中的 App 上执行现代 / 兼容协议的 `mcp_smoke.py`，再执行指定脚本，结束后退出该实例。
配置写入权限仅用于隔离验收，不改变用户服务权限。
隔离实例默认使用简体中文，以保持现有脚本的文字选择器稳定；可用 `--language en` 验证英文 MCP。
此语言覆盖只作用于测试进程，不修改用户偏好。

双语改动已通过两种语言的 1200 × 760 原生启动与 MCP 冒烟；下表记录的是双语改动前的完整交互验收。
本次目视和设置页交互未完成：AppleScript 操作超时，Computer Use 未获准访问测试 App。

脚本将窗口设为 1200 × 760，并通过辅助功能执行交互；界面结构或语义 help 变化后需同步维护选择器。
失败返回非零状态，不应记作通过。日志、导出配置、辅助功能树与部分截图保存在
被 Git 忽略的 `build/mcp-integration/case-*`，排查时查看该次目录。

## 覆盖范围与最近验收

| 脚本 | 覆盖范围 | 2026-11-11 |
| --- | --- | --- |
| `verify_configuration_ui.py` | 参数草稿刷新 / 冲突解决；原生导入导出；非法文件拒绝；替换确认及保留硬件映射 | 通过 |
| `verify_endpoint_ui.py` | MIDI 端点设置；默认自动 Port 1；隔离模式禁止应用实体端口 | 通过 |
| `verify_functions_ui.py` | 步进 / 指定 / 循环按键；参数吸附；整行分配预览确认及保留运行值 | 通过 |
| `verify_output_ui.py` | 本机 OSC 仿真；使能、限速、停机；实际 LED；接收端断线 / 重启后重新使能 | 通过 |
| `verify_precision_ui.py` | 相对 1 / 2、每格步长编辑；Mock NRPN 回路与 14-bit 读数 | 通过 |
| `verify_review_fixes_ui.py` | MCP 保护使能参数；复位跳过报告；启用可选机械臂预览及极大有限值渲染 | 通过 |

本轮 OSC 接收端丢失后 309 ms 内告警；它是本机仿真结果，不代表真实机械臂的停机保证。
端点脚本仅验证隔离界面与默认选择；实际设备枚举、手动路由和 USB 重连仍按 R1 验收。
