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

失效清理不依赖上层回调：非法 JSON、发送失败或队列溢出都会立即取消 socket、收发任务与 session，
上层安全门同时停止输出。主动停止仍尝试有界停止幀。路由选择通过 OutputTransport 协议执行，
注入不支持所选协议的适配器时明确报错；切换/停止后旧回调失效，重新启动重新挂接。
GUI安全门与新远程工具使用同一runtime单调时域。旧transport Date时间戳按连接anchor保守映射、保留排队age；
网络ping/pong RTT仍沿Date接口，系统校时可能导致偏安全的超时/拒绝，需重连并重新确认使能。

共享核心迁移后，心跳间隔达到超时期限即撤销武装，即使新心跳先于下一次评估到达也须关闭/开启使能；
回退/非有限心跳时间会锁定clockError。旧Date API只在宿主投影为注入秒数，网络包、session/epoch/序号与地址格式不变。

OSC使用Float32 wire：初始/重武装实际值必须精确可表示，否则停帧并提示参数，不做epsilon或偷偷改实际值。
WebSocket/rosbridge JSON使用Double，不因非Float32实际值（例如0.1）无故拒绝。远程disable与GUI参数共用同一policy值，
关闭后轮询不会重新开启；须实际观察到使能off/on。新远程enable默认拒绝授权，详见 [共享远程工具](SHARED_REMOTE_TOOLS.md)。

输出未启用时，空配置、仅开关配置或已保存但尚未修正的限位不会在启动阶段制造输出错误；不安装无效安全门，也不连接传输。
显式启动仍完整校验并报告失败。设置文件本身的读取/解码失败继续立即可见。
