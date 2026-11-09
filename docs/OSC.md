# OSC 仿真输出（WP6）

运行 `python3 tools/arm_sim.py --port 9000`，在 App 顶栏打开“输出”，
使用 `127.0.0.1:9000`，检查每个参数的软限位、单步变化和速度，启动适配器。
默认使能参数为 `arm.enabled`；Mock 的 B2-1 开启使能后，旋钮、滑块、MCP 都经过同一安全门。
这是一套仿真协议，真实执行端需实现相同校验与独立的停机保护。

## 线格式

遵循 [OSC 1.0](https://opensoundcontrol.stanford.edu/spec-1_0.html) 的四字节对齐、大端编码、
float32/int32/string 与 immediate bundle（timetag=1）；不接受未来调度包。
参数 ID 按 UTF-8 百分号转义，保留字母、数字、点、下划线、短横线。

- App 每 100 ms 发 `/bcr/heartbeat ,i <nonce>`。
- 接收端回 `/bcr/heartbeat ,is <nonce> <boot-epoch>`；epoch 是每次进程启动随机生成的 32 位十六进制字符串。
  App 只接受尚未过期、实际发出的 nonce，拒绝乱序。
- App 命令为一个原子 bundle，按顺序包含 `/bcr/epoch ,s <epoch>`、`/bcr/frame ,i <sequence>`、
  `/bcr/enable ,i <0|1>`，随后为零到多个 `/bcr/param/<id> ,f <value>`。
  关闭命令不带参数。接收端先完整验证，拒绝旧 epoch、重复/倒序帧、重复参数及非有限数。
- 接收端每 50 ms 回一个 bundle：`/bcr/state/epoch ,s <epoch>`、`/bcr/state/frame ,i <sequence>`，
  随后 `/bcr/state/<id> ,f <actual>`。App 拒绝旧 epoch、倒序状态及重复参数。
- 仿真端同一时间只接受一个新鲜心跳对端，350 ms 无心跳自动停止并释放对端租约。

## 安全门与反馈

20 ms 调度周期，App 心跳/实际状态新鲜度 300 ms。断线、过期、非法数值或时钟倒退关闭安全门，
发一次停机帧并告警；UDP socket ready 不能代替对端心跳。
每次重新使能或接收端重启都从新鲜实际状态开始限速，避免重放旧输出。
每次移动上限为 `min(单步最大变化量, 最大速度 × 实际经过时间)`，并限制在软限位内。
float32 量化向允许区间内收敛，不能因四舍五入越过安全边界。
设置/参数定义变化时停止适配器，必须确认新设置再启动。

输出页同时显示软件目标、安全门输出、接收端实际值。外部实际值从不修改软件目标；
LED 来源可选目标或实际。实际模式只投影连续参数的编码器，按钮和触发功能保持目标语义。
停用适配器恢复目标 LED；丢包、超时、错误均可见。MCP `get_status` 可读取安全门及重新使能基线，
参数结果提供只读 actualValue/outputValue。默认输出关闭，无网络或 Keychain 自动授权依赖。
