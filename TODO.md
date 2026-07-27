# BCR2000 Agent Console 开发 TODO

状态（截至 2026-07-27）：Swift MVP（Mock）与硬件镜像、双向反馈、基础映射已实现。当前待办聚焦于 Codex 接入与安全生产化。

## 后续开发 Plan（Todolist）

- [ ] P0-S1：完成 Codex App Server 生命周期
  - [ ] `CodexProcessSupervisor` 实现 App Server 进程 `launch/read/stderr/stdout/退出回收` 全链路，支持可控重启与崩溃恢复
  - [ ] 错误码分类 + `stderr` 诊断日志脱敏落库
  - [ ] 应用退出时无残留子进程与任务
- [ ] P0-S2：完成 Codex Handshake 与 Thread/Turn 基础链路
  - [ ] 实现 handshake：`initialize`、`initialized`、`account/read`、`model/list`
  - [ ] 实现线程与回合基础链路：`thread/start|resume`、`turn/start|interrupt`
  - [ ] `model/list` 采用分页读取并持久化模型能力（包括 effort/metadata）
  - [ ] 生成与解析 `turn/started`、`turn/completed`、`item/*` 事件的最小状态机
- [ ] P0-S3：审批安全门完整落地（无可见性误放行）
  - [ ] 硬件 approve/decline 增加 `可见性 + slot-id + request-id + 时序窗口` 三重校验
  - [ ] 实现 `commandExecution` / `fileChange` server request 的一次性响应：approve 与 decline 支持
  - [ ] 审批请求超时、重复响应、重复 request 的幂等处理
  - [ ] 无敏感信息日志：token/password/env/filepath/sensitive prompt 脱敏
- [ ] P0-S4：基础集成与稳定性
  - [ ] 关键集成测试：`mock app-server` + 真实 `swift test` 的 protocol/integration 覆盖
  - [ ] App Server 异常路径：提前退出、乱序响应、重复请求、错误响应、Malformed JSONL
  - [ ] `Stop All` 与重连场景下状态一致性回归

当前 M4/M5 的已完成项仍在保留，未完成项将按上面清单推进。

- [x] M0：工程骨架与 Mock 轨道已完成  
  - [x] Swift Package + SwiftUI executable 建好  
  - [x] Domain type 与基本状态机落地  
  - [x] CoreMIDI 热插拔与原始事件展示  
  - [x] 14 条单元测试 + 基础流程脚本

- [x] M1：端点发现与采集已完成  
  - [x] BCR2000 枚举与重连回调稳定  
  - [x] Note/CC 采集路径打通  
  - [x] 快速学习绑定 8 槽位

- [x] M2：映射与反馈已完成（MVP）  
  - [x] 映射文件持久化  
  - [x] LED/旋钮反馈回写  
  - [x] 回环抑制与 event echo 限制  
  - [x] 硬件镜像页支持 32 控件状态展示（旋钮 + IN/OUT）

- [x] M3：Mock agent console 已完成  
  - [x] 8 槽位状态机与 approval 流  
  - [x] 长按 Stop All 与硬件交互  
  - [x] UI 与硬件状态投影一致

- [ ] M4：Codex Adapter 基础（P0）
  - [x] 固定 Codex CLI 与 JSON Schema 版本（0.145.0 文档化），增加 schema 生成与校验入口
  - [ ] 建立 App Server 进程生命周期管理（启动/重启/关闭与日志分流）  
  - [x] 完成 JSONL 传输、request-id 追踪、超时与失效响应处理
  - [ ] 完成 handshake：`initialize`、`initialized`、`account/read`、`model/list`  
  - [ ] 完成 thread/turn 基础链路：`thread/start|resume`、`turn/start|interrupt`  
  - [x] 加入最小 `Mock<->Codex` 契约测试（至少请求/响应超时与响应匹配）

- [ ] M5：安全与批准（P0）
  - [x] Safe Read 与 Workspace Write 权限模型切换落地（无 network）
  - [ ] 仅在可见 UI + 对应 slot/requestId 时允许硬件 approve/decline  
  - [ ] 命令执行与文件变更审批 request 一次性响应（支持 decline）  
  - [x] `cwd` 与 writableRoots 规范化后再发起，阻断越界路径
  - [ ] 脱敏审计日志（禁止写入 token、密码、环境变量、完整 prompt）

- [ ] M6：稳定性与回归（P1）
  - [ ] 反馈调度器限速、同控件去重、错误抑制策略可配置化  
  - [ ] 断线重连恢复策略：仅恢复软件快照，旧输入清空，不重放旧队列  
  - [ ] 完成 protocol/状态机集成测试与 30 分钟 soak 验证  
  - [ ] 发布链路补齐（签名策略、版本元数据、清理文档）

- [ ] M7：映射与可配置性（P1）
  - [ ] 完成全部 32 控件的实际采集与 CONTROL_MAP 细化  
  - [ ] 映射冲突检测与手工覆盖 UI（端点、槽位、旋钮行为）  
  - [ ] 支持切换编码器输入模式（absolute / relative）及回放标定  
  - [ ] 会话配置导入导出（不包含用户私密信息）
