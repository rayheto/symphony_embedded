# M4 持久化与副作用恢复加固 — 交付记录（部分）

对应任务 T15 的可独立完成部分。只记录 **实际执行** 的结果；未运行的项为 `not_run`，
外部不可得的项为 `blocked`。

本切片新增两处机制，其余能力在 M1/M2 已实现并有测试，这里只做状态登记，不重复声明。

## 本次新增

### 孤立 blob 回收（TC16）

| 接口 | 行为 |
|---|---|
| `Store.orphan_blobs/1` | 报告本 data root 下没有任何 journal 记录引用的 blob（只报告，不删除） |
| `Store.reclaim_blobs/2` | 删除调用方点名的 blob，并在删除前重新从 journal 文件重建引用集合 |

- 引用集合来自**所有** project 的 journal 文件，包括本进程从未打开过的 project：blob 在
  整个 data root 内共享，未加载的 project 的引用同样保护字节。
- 删除前重建引用，所以“先报告、后删除”之间写入的记录不会失去它命名的字节。
- 只删除调用方点名的 digest；任何未被点名的 blob（包括历史原件）都不会被自动删除。
- journal 读不出来时返回 `:journal_unreadable` 而不是空引用集合：**证明不了无人引用**不能
  被当成**无人引用**。

### 未知物理结果的隔离（TC22）

| 行为 | 说明 |
|---|---|
| `outcome` 字段 | 退出码 0 → `confirmed`；非零 → `uncertain` |
| 非幂等动作非零退出 | 进入隔离，回执带 `quarantined` 条目（tool_id / exit_code / 时间 / 回执摘要） |
| 隔离期间重复调用 | `{:error, :action_quarantined, ...}`，并提示先 probe |
| `probe` 清除隔离 | 返回 `cleared_quarantine`，说明这次观测清掉了什么 |
| 幂等动作 | 非零退出同样记为 `uncertain`，但不隔离——重复幂等动作不会改变物理结果 |

依据：没有人看见结果的非幂等动作（flash/write）再执行一次可能真的再刷一次；因此隔离的
解除条件是**观测**，不是超时，也不是重试。

## 已有能力与对应测试（M1/M2 交付，此处仅登记）

| 能力 | 测试位置 |
|---|---|
| 尾部截断报告、中段损坏停止写入 | `store_test.exs` "journal integrity" |
| blob 写/改名故障注入 | `store_test.exs` "blob fault injection" |
| journal 写/fsync 故障注入 | `store_test.exs` "journal write fault injection" |
| 索引重建不重编号 | `store_test.exs` "restart and recovery" |
| 双 writer 拒绝（lock 文件各形态） | `store_test.exs` "lock file shapes" |
| data root 必须在 workspace 之外 | `store_test.exs` "data root rules" |
| 事件游标、重复事件、过期游标 | `store_test.exs` "events"、"event broadcasting" |
| 跨 project 引用与实体守卫 | `store_test.exs` "project id and entity guards" |
| 采用方案的分步回执 | `operations_test.exs` "adopting a decision" |
| 租约代次、过期、owner/generation 拒绝 | `manager_test.exs` "leases"、"actions" |

## 未完成与阻塞

| 项 | 状态 | 原因 |
|---|---|---|
| TC16 磁盘耗尽 | `not_run` | 未在本环境构造真实磁盘耗尽场景；只有 blob 大小上限的拒绝测试 |
| TC05 换 build/config 后显示 stale | `not_run` | 需要真实目标构建与固件绑定（环境中 `device` 全为 null） |
| TC15 浏览器侧隔离断言 | 部分 | 产物端点的 server 侧已断言（无 session/CSRF/应用壳、`connect-src 'none'`）；iframe 实际隔离需真实浏览器，本环境 Chrome 无法访问网络见 `m3-architecture.md` |
| TC15 恶意 HTML | `not_run` | 需要对真实交付的 HTML 做浏览器侧验证，同上 |
| TC22 真实可控动作 | `blocked` | 没有接入目标板；隔离与租约行为在 PTY/桩动作上验证 |
| TC21 断开 LiveView 后带 cursor 恢复 | 部分 | 游标与重复事件在 store 层有测试；未做真实断线重连的浏览器侧验证 |

## 门禁证据

命令：`cd elixir && make all`（退出码 0）

| 步骤 | 结果 |
|---|---|
| `mix format --check-formatted` | 通过 |
| `mix specs.check` | 通过 |
| `mix credo --strict` | 0 issues |
| `mix test --cover` | 799 tests, 0 failures, 6 skipped, 100.00% |
| `mix dialyzer` | Total errors: 0 |