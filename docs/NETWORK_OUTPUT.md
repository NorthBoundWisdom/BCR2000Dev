# WebSocket 与 ROS 2 参数输出

输出设置支持 OSC UDP、WebSocket JSON、ROS 2 rosbridge。三种适配器共用 OutputController 和 MotionSafetyGate，
所以软限位、单周期变化、速度、使能边沿、300 ms 心跳/实际值期限和断线停机规则一致。
启动应用不会恢复运动输出；修改输出设置需重新手动启动并确认使能。

WebSocket 使用 `ws://<目标地址>:<端口>/`。ROS 2 模式连接 rosbridge 的 WebSocket 端点（常见端口 9090），
遵循 [rosbridge 协定](https://github.com/RobotWebTools/rosbridge_suite/blob/ros2/ROSBRIDGE_PROTOCOL.md)。
它不是原生 DDS 客户端，远端需 rosbridge 与实现下面参数链路的接收节点。
适配器不引入 Swift SDK 或本机 ROS 依赖。仅用于受信任的本机/隔离网络仿真；不把明文 ws 当作跨公网认证通道。

## 参数链路

JSON 中的 sequence 是十进制字符串，避免 JavaScript 大整数精度问题。每次连接建立新的 session UUID。
客户端先发送：

```json
{"type":"ping","session":"client-uuid","sequence":"1"}
```

对端必须在 300 ms 内回显 session 与 sequence，并提供每次对端启动都改变的 epoch：

```json
{"type":"pong","session":"client-uuid","sequence":"1","epoch":"peer-epoch"}
{"type":"state","session":"client-uuid","sequence":"1","epoch":"peer-epoch","values":{"arm.j1":0}}
```

state 使用独立单调递增序号。旧 session、epoch、重复/乱序状态和过期心跳丢弃；epoch 变化会重置安全门，
需要重新确认使能。非法值、未知参数由链路或安全门拒绝并停止输出。

使能且安全门允许后，发送经过限制的输出：

```json
{"type":"command","session":"client-uuid","sequence":"2","epoch":"peer-epoch","enabled":true,"values":{"arm.j1":0.5}}
```

停止幀必须 `enabled:false` 且 `values:{}`。主动停止会尝试发送该幀并在 200 ms 内关闭连接；
连接已经丢失时，对端必须由自身看门狗停机。发送队列上限 64，单条接收消息上限 1 MiB。

## ROS 2 映射

使用 `std_msgs/msg/String`，其 data 字段保存上述 JSON。客户端 advertise 两个请求主题并 subscribe 两个回传主题：

| 方向 | 主题 | 参数链路类型 |
| --- | --- | --- |
| 客户端 → ROS 2 | `/bcr/heartbeat/request` | ping |
| ROS 2 → 客户端 | `/bcr/heartbeat` | pong |
| 客户端 → ROS 2 | `/bcr/command` | command |
| ROS 2 → 客户端 | `/bcr/state` | state |

```json
{"op":"publish","topic":"/bcr/state","msg":{"data":"{\"type\":\"state\",...}"}}
```

本机测试使用真实 URLSession WebSocket 与独立 RFC6455 模拟端，验证 WebSocket 和 rosbridge 包装、心跳、
状态、命令、停止幀；核心测试验证 session/epoch/序号、过期心跳与非法停止幀。
这项验收不代替 ROS 2 部署环境、真实机械臂或独立硬件急停评审。
