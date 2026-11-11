# Provider API 1.0：首批合同

范围决定见 [ADR 0001](adr/0001-provider-domain-boundaries.md)。本合同只约定本机 macOS 的控制台、
参考关节机器人和 Ackermann 底盘；明确标记 mock、hardware、simulation，不从地址推断来源。

## 运行与发现

GUI 和 `BCRProviderService` 无界面宿主复用领域与应用服务。服务只监听 `127.0.0.1`，
`POST /mcp` 采用现有 MCP JSON 调用；`GET /mcp` 提供鉴权 SSE。首批保留现有工具兼容。
控制台、机器人和底盘为可选能力；缺失或未启用时明确返回 unsupported，不自动启用另一种实现。
可用权限由启动配置声明，网络客户端不能自行授予。真实执行器和厂家原生协议不在本合同范围。

公开能力查询给出 contract_version、资源 ID、模型、来源、单位、坐标系、运行时钟、已支持/未支持命令、
权限和事件限制。Schema 与公开客户端随发布产物提供；消费方不需要源码目录或私有配置文件。

`provider_id` 是本次应用/服务进程启动时生成、不可配置的 UUID，由 `provider.ready`、
`provider_capabilities`、`provider_state` 返回。GUI 仅重启 HTTP 监听时保留它；整个进程重启时更换。
模拟设备资源 ID（`robot.reference`、`chassis.reference`）只在该实例内定位，不能当作跨实例身份；
控制台工具作用于当前实例的唯一控制台。
消费方从进程所有者取得可信 `provider_id`，SDK `expected_provider_id` 将其放入每个 RPC/SSE 请求的
`BCR-Provider-Id` 头；鉴权后、执行前检查，不符返回 HTTP 409，响应也回显身份供客户端核对。
同一端口换了进程不能自动继承原控制绑定；一个模拟设备不能同时冒充多个独立实体。

合同版本为 `1.0`，命令对象 `schema_version=1`。未知字段、错误类型、错误资源/版本/操作均拒绝。
加法扩展在同一 major 下通过 capability 发现；破坏性的语义或必需字段变化必须升 major，旧接口的
移除需先在能力清单声明废弃。`provider_contract` 和 `tools/list` 返回可独立校验的完整输入/输出 Schema。

## 首批能力

| 领域 | 命令与读数 | 明确未支持 |
| --- | --- | --- |
| console | 现有控件/参数/映射/学习/反馈工具，加有界来源事件读取 | 通过参数写入伪造硬件输入或业务审批 |
| robot | 初始化、获取/释放控制权、使能、关节运动、停止/失能、状态、重置、模拟故障 | IK、厂家程序、真实驱动、连续碰撞资格 |
| chassis | 初始化、获取/释放控制权、使能、速度/转角命令、停止/失能、状态、重置、模拟故障 | 侧移、原地旋转、真实 CAN 资格 |

机器人关节为 rad、速度为 rad/s、加速度为 rad/s²；位姿平移为 m，旋转矩阵为右手列向量。
参考关节链的 DH 参数与基座 frame 随模型发布，末端位姿由实际推进关节计算。
底盘速度为 m/s、前轮等效转角为 rad，车体 frame 为 +X 前、+Y 左、+Z 上，yaw 逆时针为正。
转角不是角速度；实际 yaw rate 为 `v * tan(steering_angle) / wheelbase`，零速度不旋转。
能力清单还给出可机读 `frame_id` / `coordinate_convention`；机器人矩阵布局是
`row_major_column_vector`，底盘姿态是 `x_m_y_m_yaw_rad_ccw`。本版仅支持这些 frame 和单位，
不接受未知 frame 字段，也不做隐式单位、坐标或机器人型号转换。

## 控制与状态

每个模拟设备独立维护 generation、sequence、时钟、初始化/使能、控制权、故障及执行状态。
初始化后才有已知实际位姿；获取控制权不自动使能。命令目标与实际状态分别返回。
命令接受不等于完成：状态区分 idle、running、stopping、stopped、disabled、fault、uninitialized。
状态快照不暴露控制令牌；令牌只返回给成功申请者。

带控制权的命令绑定当前 generation、控制令牌、严格递增序号和有效期。
重复序号、旧 generation、过期控制权、非有限数、越限及不支持操作均拒绝，不静默夹紧。
HTTP 结果未知时读取状态/最后接受序号核对，不盲目重发。断线后不自动恢复旧命令。
运动超时或失去控制权触发停止；停止状态必须来自模型推进和实际速度归零。
重置、故障与恢复只影响指定资源，旧令牌/序号随 generation 废止。

控制权 TTL 为 0.1–5 s；运动命令独立声明 `valid_for_s`。实时时钟无需状态轮询即可触发失效保护，
手动时钟仅在显式 `simulation_advance` 时推进，供确定性测试。到达失效边界立即开始减速，不能把
整个大步长当作仍然有效的运动。底盘进入 `stopping` 后不能用新 `drive` 取消停止，停稳前 `enable`
或 `release` 返回 busy；机器人在已有运动/停止计划完成之前也拒绝新计划。
关闭全局写入或某领域控制权限会废止该领域旧控制权并触发有界停止，权限恢复不恢复令牌或目标；
其他领域、Agent 会话和控制台配置不因此重置。

机器人首批使用满足显式速度/加速度上限的关节插补；停止从当前状态减速，目标不冒充实际关节。
底盘按显式速度、转向变化率和加减速约束积分，停止后继续报告真实推进后的姿态。
故障注入与人工时间推进需要独立仿真权限，不能由只读或 Agent 权限隐含取得。

## 事件与时钟

参数 SSE 保留 revision；控件级事件另有 generation、单调 sequence、UTC 观测时间、来源、
控件标识、原始值、映射值及 accepted/ignored 信息。硬件、Mock、软件、Agent、外部写入、
反馈/回显和诊断回读分开。反馈及回显不是用户动作，来源信息也不是人的身份签名。
换源、断开、换映射或重置废止旧代次；重连先读取快照，不回放旧输入。

输入事件与执行 trace 均有有界库存，暴露最早/最新序号与丢弃计数；过旧游标返回明确缺口。
SSE 沿用有界队列、慢客户端断开和重新取快照规则。首批本机验收目标为正常调用 2 秒内完成，
事件观察在 2 秒预算内；不能通过延长新鲜度来掩盖失败，长时间/高频资格另留实测记录。
仿真支持实时时钟与显式手动时钟。手动推进只作用于指定设备；单次步长有限，并保持独立代次。

`BCR-Event-Stream` 选择 `parameters`、`console` 或 `devices`（仅注册的频道可用），
通知分别为 `notifications/bcr/parametersChanged`、`notifications/bcr/consoleEvents`、
`notifications/bcr/devicesChanged`。每次订阅首先返回 `reset=true` 快照，不能把库存里的历史输入
作为新动作执行。控制台事件库存为 512 条，单次读取最多 256 条；16 ms 合并保留事件顺序，
一批超过 512 条或慢读者超过有界字节队列时关闭订阅，不无声丢弃后续输入。硬件/映射上下文
在处理一条输入期间变化时，旧输入不作为新 generation 的 accepted 动作发布。
首批软件黑盒覆盖 100 条同批事件有序合并、溢出断流和观察者释放，不宣称持续硬件吞吐资格。
每个服务最多 16 个 SSE 订阅，每订阅快照预算 8 MiB、增量预算 65,536 bytes（包括在途数据），
10 s 心跳。客户端丢流后须重新取快照及新鲜状态，不把新快照中的历史动作补执行。

## 兼容与错误

新配置用显式字段声明外部写保护。旧机械臂示例保护由配置迁移适配器恢复，
与通用会话、默认参数名和通用设备无关；保存迁移文件前保留原始备份。
旧 MCP 工具保留其既有错误格式；新设备接口返回稳定错误码与不含令牌的原因。
首批错误至少区分 invalid_argument、unsupported、not_initialized、disabled、faulted、busy、
stale_generation、stale_sequence、invalid_control、control_expired、command_expired、event_gap。
新工具结果为 `data`（业务数据）或 `data.error`（结构化 code/message，且 `isError=true`）；
HTTP 鉴权、实例 pin、语法与媒体类型错误在工具执行前失败。错误不回显控制令牌或 Bearer 凭据。

公开原生诊断工具仅请求 identity/CC snapshot，在 `console_diagnostics begin/end` 期间将设备接收标为
`origin=readback`，不作为操作者输入。它要求实例 pin 和设备控制权限，不写预设、不猜映射。
异常退出后诊断隔离保持，所有者需检查状态并显式 abort，不能自动把迟到回读变成新输入。

机器人/底盘的模拟合格不授予真实硬件资格。实际控件编码、断插和灯环视觉结论按实测范围声明，
未验证的实体 Relative/NRPN 行为明确列为未资格化；不借用软件测试结果代替。
