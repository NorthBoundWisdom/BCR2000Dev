# WP6 交接：安全门与 OSC 仿真

已在本机 main 实现并验证，只作本地提交，不推送；继续 WP7。

- Core 纯值安全门统一限制硬件、滑块、MCP 目标；使能、软限位、单步变化、速度、断线、
  300 ms 心跳/实际状态新鲜度、时钟倒退均有确定性测试。首次开启以新鲜实际值为基线。
- ParameterSink/Source 边界、严格 OSC 编解码、App Network.framework UDP 与独立标准库仿真器。
  epoch/序列号/对端租约拒绝旧进程数据与乱序重放；禁用和超时停止。
- 输出设置和目标/输出/实际三列读数；实际 LED 可选，不污染软件目标；设置或参数定义变化停止输出。
- float32 向安全区间内量化，测试边界无越限。目标吸附不应用于实际遥测。
- 原生最小窗口验收：Mock 使能，MCP 写目标，观察限速分离；禁用后仿真停机；实际 LED 与目标分离；
  杀死仿真端后 UI 278 ms 告警；重启后从新鲜实际状态恢复。现代/旧版 MCP 冒烟通过。
- Swift 新增 MotionSafetyTests 9、OSCCodecTests 7、OutputControllerTests 3；
  Python 仿真 6 条覆盖超时/速度/原子性/租约/重放及旧 epoch。完整检查结果见本地 build/wp6-*.log。

协议与启动见 [OSC.md](OSC.md)。WebSocket/ROS 与可选 dead-man 未实现，不属于本包必需项。
未接真实机械臂，也没有将 UDP 连接状态当作执行端在线证明。真实设备独立停机策略仍需后续验证。
审查重点：新鲜度、重新使能基线、float32 边界、整个帧校验后应用、实际值与软件目标隔离。
