# Appendix B. Embedded Engineering and Human Experience Profile

状态：本项目扩展规范。下列 MUST/SHOULD 沿用原 SPEC 的规范词含义。本扩展启用时适用；未启用时保留原 core 行为。原 §1–18 与 Appendix A 保持原意。本扩展不重新定义 scheduler、tracker 内核或通用审批政策。

## B.1 启用与配置

`workbench.enabled` 默认 false。启用后挂载 `/workbench`；`/` 保持原运行 dashboard，导航可从工作台进入。沿用原 `server.port` / `--port` 启用 HTTP 的方式；启用 workbench 未启用 HTTP 时给出可见配置错误，不静默启动新监听器。
`workbench.project_id` 必填且稳定；`workbench.data_root` 必须在 workspace.root 外，默认 WORKFLOW 同目录 `.symphony-data`；`workbench.domain_profile` 默认 WORKFLOW 同目录 `embedded-profile.yaml`；`workbench.mode` 默认 live，demo 必须显式选择，禁止凭缺凭证自动退回 demo。
`workbench.display_states` 默认为 active+terminal 去重；实际 Linear profile 须包含 Human Review、Paused、Backlog 等显示状态；这些不是新增 dispatch 状态。
`workbench.archify_root` 是已安装 skill 中含 `bin/archify.mjs` 的目录；未配置时架构生成 capability unavailable，已有产物仍可查看。`workbench.device_config` 默认同目录 `devices.yaml`；未配置设备时显示空态。
配置均由原 Config/Workflow 管道读取、相对路径相对 WORKFLOW。展示筛选与样式可热更新；data_root、project_id、设备端口和 Archify 版本变更需显式重启相应资源，保持原会话绑定不漂移。无效 reload 保留 last-good 并显示错误。

## B.2 权威与边界

MUST 保留 Orchestrator 对 dispatch/claim/retry/reconciliation 的唯一权威。工程记录、前端状态和 humanized strings MUST NOT 驱动 core 状态转移。
MUST 保持 tracker 原生工单状态权威。产品可有 ProblemCase、Review、Operation 状态，但不再维护第二份 Issue 状态机。
工作台的读写经 provider-owned WorkbenchAdapter capability，复用既有 provider client/auth；不得给 core Tracker 增加通用工单 CRUD。可选界面失败不影响后台编排。
领域政策 MUST 从仓库的 WORKFLOW 和 domain profile 获取。对话意见是带版本的项目输入，通过 workpad/计划引用传递，而不是修改全局模型设置。

## B.3 工程对象

MUST 支持 ProblemCase、Claim、Evidence、Validation、Decision、Review、Operation、DeviceSession、ArchitectureArtifact 及与原 Issue/Run 的关联。规范字段见 `contracts/entities.schema.json`，API 见 `contracts/openapi.yaml`。
MUST 分别呈现实行状态、验证状态、人类审阅、Agent 判断。worker 正常退出不等于产品验收通过。原始证据的哈希、适用条件与修订不可静默改变；更正通过新修订或 supersedes。
ProblemCase SHOULD 在发现问题时更新，保留失败尝试、当前假设和剩余疑问；缺证据可记录，但不得假装已解决。

## B.4 人类操作

支持版本化评论、请求补证据、采用候选方案、暂停/恢复 Issue、创建 Issue。作用域首版为一个 Issue；跨 Issue 的影响列明为相关集合，逐项显示结果，不提供虚假原子事务。
读与选中候选不是批准。采用方案不是执行或验证。操作提交 MUST 检查 actor、scope、expected_revision、idempotency_key 和 capability；按 `STATE_AND_CONSISTENCY.md` 提交与对账。
暂停 MUST 通过原生非 active、非 terminal 状态表达，恢复必须符合既有工作流；不得 close 工单实现暂停。若 provider 不具备该能力，明确不支持，不伪造本地暂停。
人类等待使用仓库配置的非 active 状态，不增加 claim state 或自动重试原因。默认 handoff 非阻塞，仅明确的方向性约束/待决定边界进入 Review。
操作未返回确认不得显示完成；provider 写入超时显示 outcome_unknown，先对账后决定是否重试；不能重发可能已成功的 create 或非幂等设备动作。

## B.5 Archify 架构产物

MUST 使用固定版本 Archify skill，根据具体项目的代码/设计材料生成。宿主只负责选版本、触发既有工作流、保存和呈现产物，不实现第二个图形渲染器。
源码图 MUST 绑定完整 Git revision、来源路径及 `--repo-root` 检验。计划图明确标计划来源，不宣称代码已实现。工作区未提交修改不得用 HEAD 图冒充覆盖；展示不覆盖差异的提示或生成标为设计草稿的独立图。
MUST 保留 IR、HTML、deliver 回执、浏览器回执和独立视觉审阅结果，且哈希绑定同一产物。发布候选失败保留 last-good 并显示失败/过期；不能把旧图当新图成功。
L0–L4 仅是领域视角，反馈横跨所有层，不要求节点按单链排列。关系、Issue 和证据链接来自实际来源；不得从图形邻近关系推断因果。

## B.6 设备与证据

所有硬件动作由宿主 DeviceAdapter 控制。设备连接、观测、控制租约、验证结果分开表示。独占动作检查租约代次；串口单采集者，多只读订阅。
串口原始 bytes、采集序号、接收时间、boot/session 和丢失缺口 MUST 保存；前端可降采样，原始记录不隐式删减。串口心跳不能喂活 Agent stall timer。
dump 必须保留原始材料，符号不匹配时拒绝确定性解码结论。图像是观测材料，不是硬件控制状态。无故障记录不表示无故障。
设备状态未知时，非幂等动作不可自动重复。Agent 进程停止不保证物理设备停止；工具层须报告真实动作终态与恢复需求。

## B.7 存储与恢复

原 §8.6/§9 workspace 清理继续执行。证据在 data_root 持久化，不依赖失败可忽略的 before_remove hook 抢救。存储不可用时必须向证据工具返回失败，工作流不能宣称该证据验收已完成；core 仍可调度其它工作。
core 重启仍按 §14.3 重建运行。工程 Store 单 writer、原子提交并可重建索引；Operation 恢复只对账已有效果，不盲目执行。Archify/blob 与工程记录丢失不能反向改变工单。

## B.8 HTTP、权限与正确性

新增 API 在 `/experience/v1`，避免原 `/api/v1/:issue_identifier` 冲突。保留原 baseline endpoints。
浏览器变更请求继承 Phoenix session/CSRF 和宿主身份；不得把 API key 放到浏览器。默认 loopback；跨机器使用由部署提供受信任身份代理，未经配置拒绝远程写操作。
Archify HTML 以隔离 viewer 呈现并禁止获得应用 session 权限，不能作为普通 HTML 插入父 DOM；证据下载按项目 scope、路径 containment 和哈希授权。

## B.9 验收

原 §17–18 core gates 全部保留；新增 R01–R12 映射到本包 TC 场景。Demo/PTY/Host 证据不替代真实 tracker、Codex 与硬件证据。UI 可关闭，工作流应继续按有效政策运行。
