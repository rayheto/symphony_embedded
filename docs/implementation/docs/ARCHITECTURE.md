# 系统架构与实现边界

## 基线检查

已有：`elixir/lib/symphony_elixir/{orchestrator,agent_runner,workspace,workflow,config,tracker}.ex`；`elixir/lib/symphony_elixir_web/{router,observability_pubsub,presenter,static_assets}.ex`；LiveView `live/dashboard_live.ex`；静态资源 `elixir/priv/static/`。
已有 dashboard 展示运行，不是完整 Issue 管理界面；设计附件中的看板需要新增，不能仅从 running map 推导 Todo/Done。项目架构生成指的是工作台所管理的目标项目，不把 Symphony 自身源码和目标设备混在一张图里。

## 推荐新增模块（路径相对目标仓库）

| Owner 模块 | 路径 | 输入→输出 / 不得承担 |
|---|---|---|
| Experience.Store | `elixir/lib/symphony_elixir/experience/store.ex` | typed records/blobs→持久化修订、读取、索引；不调度 Issue |
| Experience.Query | `.../experience/query.ex` | tracker + runtime + Store→快照；每块标新鲜度，不伪造跨服务事务 |
| Experience.Operations | `.../experience/operations.ex` | actor/请求→provider 调用和回执；无 ticket business rule 副本 |
| Linear.WorkbenchAdapter | `.../linear/workbench_adapter.ex` | provider-specific list/create/comment/state/plan attachment；复用 Client |
| Experience.AgentTools | `.../experience/agent_tools.ex` | problem/evidence/validation 上报；会话绑定项目/issue，不能冒充人类 |
| Experience.Architecture | `.../experience/architecture.ex` | 固定 revision 的请求/清单→Archify产物索引；不生成布局 |
| Devices.Manager | `.../devices/manager.ex` | 登记/租约/boot与连接→设备状态；不修改 core concurrency |
| Devices.SerialPort | `.../devices/serial_port.ex` | Port JSONL→原始流/事件/缺口；不要阻塞 Orchestrator mailbox |
| Device helper | `elixir/priv/device_helper/` | 固定 allowlist 命令，pyserial、PTY 测试；版本与依赖锁定 |
| Workbench LiveViews | `elixir/lib/symphony_elixir_web/live/workbench/` | issues/issue_detail/architecture/devices/reviews；共享 shell 组件 |
| API Controller | `elixir/lib/symphony_elixir_web/controllers/experience_*` | 同一领域函数；不和 LiveView 各写一套 mutation |

`.../` 是上一行共同前缀的缩写，实际实施用完整 Elixir 模块目录。M0 核对基线后的目录映射记录到 ADR；无需为命名微调阻塞，但不得变更职责。

## 数据权威

| 事实 | 权威 | 缓存/读取方式 |
|---|---|---|
| Issue 当前状态/标题/负责人 | provider | TTL 快照、updated_at、失败时旧值标 stale |
| claim/running/retry | Orchestrator | 原 snapshot/PubSub，只读 |
| workflow policy | repo WORKFLOW/profile | 原 reload；会话保持绑定 |
| 当前 issue 计划引用与进展 | provider workpad | 引用不可变 Decision/Plan artifact，维持单 workpad |
| 实验、证据与历史决定 | Store immutable revisions | project event journal + CAS blob |
| 设备连接和动作 | DeviceAdapter 实测回执 | session scoped；失联 unknown，不用最后状态装在线 |
| 架构 | Archify IR/HTML+来源回执 | manifest 索引，last-good 指针 |

## 事件与进程

新增模块在独立 supervisor 子树中运行；订阅原 PubSub 或极小结构化事件 hook，不能把 raw 日志/大文件发到 Orchestrator。LiveView 只接收 invalidation 和小批量行，按 cursor 拉历史。事件通知可合并，但关键工程记录先持久化再广播。
一个文件 Store writer 串行写入：blob temp→fsync→原子 rename；记录 journal 包含 revision/哈希→flush/fsync→更新索引→发通知。若崩溃在中途，允许孤立 blob；恢复扫描最后完整记录，截断尾部不完整记录并报告。禁止两个实例共享同一个 data_root 写入，通过锁检查启动。records 的 application status 与 core 状态隔离。

## 数据根目录

`projects/<project_id>/records.jsonl`、`blobs/sha256/<prefix>/<digest>`、`serial/<device_id>/<session_id>/chunks/`、`architecture/<artifact_id>/`、`indexes/`。所有外部 ID 先做无路径语义映射；用户不能传任意读写路径。原始附件及日志有 size/sha256/content_type。证据只有在 blob 和引用都完成后才 accepted。

## Issue 操作边界

首版 Linear UI adapter 实现 list/issues、create、comment/workpad 更新、transition 与原生 attachment；可调用同一个宿主 provider client，但不把方法加进 Orchestrator。WorkBenchAdapter capability 列表反映当前配置权限；字段列表、状态和负责人从 provider 读取，只有 fixture 可硬编码。
core GitHub 等 adapters 不改状态语义；未提供 WorkBenchAdapter 时可只读已支持的完整状态列表和外链，并显示具体缺失功能。PRD 的首个可用交付必须验证 Linear 完整链，不能以其它 provider 不支持为由删功能。

## 页面与图形集成

LiveView 负责壳、表单、Issue 详情；Archify viewer 负责图形内部搜索/聚焦/缩放。first-party 顶部导航不注入到图中。首版使用 sandbox iframe 加独立受控 artifact endpoint，允许脚本、下载但不 allow-same-origin；提供独立打开方式。无已证实的 postMessage 协议，首版不依赖节点点击回调；侧栏用 manifest component selector 关联 Issue/证据，viewer 原生 focus 功能照常使用。
仅把 manifest metadata 与源码关系关联；不得根据 viewer DOM 文本反推工程事实。封装隔离细节和来源链接可达性须浏览器实测；若沙箱导致导出不可用，独立打开作为明确降级，不能添加同源特权绕过。

## 规模与非功能边界

工程日志按 8MiB 或 60s 切块（先到为准）；活跃串口 browser buffer ≤5000 行；Store 单请求 metadata ≤1MiB；helper 原始payload ≤64KiB（base64 JSONL传输行上限96KiB）；blob 默认上传 ≤64MiB，原始大 dump 可按 8MiB 分块并生成整体哈希。普通实体分页默认50/max200，事件分页默认100/max500。过量输入通过 backpressure/显式 gap 处理。
串口配置默认原始证据保留 30 天，已被 Decision/Validation 引用的片段和其必要上下文 pin，除非明确存储政策变更。容量默认 10GiB，80% 提醒，满时停止新增采集并标 gap，不自动删除 pinned 证据。上述默认在 config 明确展示并记录。
