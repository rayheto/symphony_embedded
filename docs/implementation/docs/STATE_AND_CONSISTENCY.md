# 状态、控制与一致性契约

## 状态空间

core claim state 原样保留；tracker native state 原样保留。四列看板是 display mapping，不是另一份工作流。演示四列对应 Todo/In Progress/Human Review/Done。真实 Linear profile：Todo、In Progress、Rework、Merging 是 active；Human Review、Paused、Backlog 非 active 非 terminal；Done/Closed/Cancelled 等终态按实际配置。状态不存在必须 M0 配置，不自动创建或猜测。

工程 `implementation_status` 为 planned/building/integrated；`verification_status` 为 unverified/passed/failed/stale；`human_review_status` 为 unseen/reviewed/accepted/changes_requested；`agent_endorsed` 单独布尔值。UI 可同时 showing integrated + stale。

## Operation 请求与终态

received → applying → applied | failed | conflict | outcome_unknown；outcome_unknown → reconciling → applied | failed | conflict，必要时保持 unknown 等待明确处置。系统重启不把 applying 重发，先标 outcome_unknown 并对账。
相同 project+idempotency_key+request hash 返回同一 Operation；同 key 不同内容返回409。entity revision 用本地串行 CAS；provider updated_at 只能用于发送前乐观检查，不宣称有远端原子 CAS。并发外部修改在读回发现时显示 conflict，附已观察的部分效果；不自动覆盖外部字段。
按钮点击从 server session 解析 actor，客户端不能自报 human 权限。机器上报只能创建 agent/tool 类型记录，不能生成 human_accepted。

## 创建/评论

创建 Issue 前验证 provider 元信息与 scope。内部 operation marker 用于对账，第一次结果不明不得重发创建。查无结果但 provider 读暂不可靠时继续 unknown，由操作界面说明。评论先查 operation marker 防重复；常规 Agent 进度保持原工作流的单 workpad，不每个事件刷评论。

## 暂停

1. 读取 provider 当前值，检查不是 terminal、具备 Paused 状态和 capability。
2. 写原生 Paused，读回确认。此时显示“工单已暂停，等待运行停止”。
3. 原 reconciliation 在后续 tick 停止 worker，无 workspace 清理。只有 snapshot 中当前 issue 不再 running 且没有仍有活动的该 worker，才显示“已停止”。
4. provider 不可达时保持当前原语义，不伪造已停止；手动中断不能代替持久暂停。
重启从 provider 非 active 状态继续排除 dispatch；UI 断线不恢复任务。恢复请求显式携带目标 active state，需符合 workflow、依赖、权限，状态写成功不等于已开跑。

## 采用方案与修改约束

选中 A/B 仅客户端候选，不写 Decision。采用时绑定 decision_id、decision_revision、option_id、issue provider version。按次序：
1. 核对候选与依据版本，保存 immutable adopted Decision（附 actor/limits）和 Operation。
2. 若 Issue 正在 running，先走暂停流程，停止确认后再发布新计划引用；停止前保持旧引用。然后更新该 Issue 单 workpad 的 plan reference，包含 Decision URI+hash、plan_revision、约束以及验证欠项；读回引用确认。
3. 本地 adopted 表示人已决定；Operation applied 只在 provider 引用确认后成立。部分失败不撤销人的历史决定，显示“决定已记录，工作流未更新”，可对账重试更新。
4. 任一步失败或结果不明就停在相应回执阶段，先对账。不能把 WORKFLOW reload 当作当前 turn 的即时变更。
5. 是否恢复到 active 由请求的 `resume_after_apply` 和 workflow 决定，默认 false；UI 在操作前显示后果。恢复是同 Operation 的后续明确阶段，分别给回执。
6. 下次 Agent 从 workpad 读取 Decision 及哈希，报告 plan_loaded 事件绑定当前 run。出现 plan_loaded 后才显示“新方案已被执行器采用”；测试通过另行展示。
方向修改暂停范围首版只支持一个 Issue，UI 展示已知相关 Issue，不声称依赖影响集合完备，也不自动停止其它 Issue。跨 issue 批量控制不在首版，以逐项用户操作完成。

草稿内编辑约束只改变候选修订，尚未改变执行方向；对已采用方案的约束修改创建新的采用修订，保留所选option，再走上述暂停/发布/回执流程。UI明确显示两种编辑的后果。

## 补充证据与等待

request_evidence 保存针对 entity/revision 的问题并更新 workpad。active Issue 在下一有效读取边界处理；非 active Issue 保留请求并提供明确“继续执行补充验证”操作，不把留言自动等同恢复。默认没有 handoff 审批。策略指定的方向性选择进入 Human Review 并释放 worker，不无限维持活跃 turn 等待。

## 事件和缓存

project journal 分配递增 project_seq（持久化，重新索引不重置）；不同设备原始 source_seq 不等同 project_seq。客户端以 cursor 恢复；过期游标返回409 cursor_expired和重拉快照提示，不能静默漏事件。重复 event_id 不重复显示。
快照包含 snapshot_seq、generated_at、tracker_fetched_at、runtime_observed_at、source_health；跨 tracker/runtime 的时间不同要明确，不能把局部快照声称全局强一致。

## 失败边界

archify generation failed、evidence missing、serial disconnected 属工程状态，不直接变更 retry。Store 写失败让相关工具返回结构化失败并阻止假验收；其它 core 工作仍运行。库损坏停止 Experience 写入并提供只读故障状态，不重置 core。device lease 失效后不能重新运行一次烧录来确认成功，先观察设备状态。
