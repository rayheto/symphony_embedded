# 交付报告

本文件是这一版 Symphony Embedded 工作台的交付结论：哪些需求有实现、测试与证据，哪些是
`blocked` 或 `not_run`，以及为什么。**结论不是「完整发布」**：见最后一节。

工作分支：`agent/embedded-workbench`（从 `main` 的 `e0ccc837` 起）。所有结论都对应可复核的
提交与命令输出。

## 门禁

`cd elixir && make all`：格式、`mix specs.check`、`mix credo --strict`、`mix test --cover`
（100%）、`mix dialyzer` 全部通过，退出码 0。原有阈值没有降低。

| 里程碑 | 交付记录 |
|---|---|
| M0 基线与环境 | `docs/verification/m0-baseline.md`、`docs/environment/` |
| M1 工作台任务闭环 | `docs/verification/m1-workbench.md` |
| M3 项目架构 | `docs/verification/m3-architecture.md` |
| M4 持久化与副作用加固 | `docs/verification/m4-hardening.md` |
| M4 图像与 dump（部分） | `docs/verification/m4-devices.md` |
| M5 可安装与备份恢复 | `docs/verification/m5-release.md` |
| M5 视觉验收 | `docs/verification/m5-visual.md`（blocked） |
| 运维 | `docs/operations/README.md` |

## 需求追溯

状态含义：**实现并验证**（有实现、有测试、有事实验证）；**部分**（实现与测试齐备，但真实
环境那一半没做）；**blocked**（外部资源缺失，未做且不冒充）；**not_run**（未做）。

| 需求 | 实现 | 测试/证据 | 状态 |
|---|---|---|---|
| R01 完整继承原 Symphony 执行 | 原 scheduler/retry/reconciliation/workspace 未改；工作台是 `/workbench` 加法 | `core_test` 等原测试全绿；`make all` 100% 覆盖 | 实现并验证 |
| R02 Issues 看板/列表 | `Workbench.IssuesLive`、`IssueDetailLive`、`Operations` | `workbench_live_test.exs`（看板四列、筛选、创建、详情四页签、回执） | 实现并验证（真实 Linear 项目 `blocked`） |
| R03 问题调查 | `Experience.AgentTools`（`engineering_read`/`engineering_report`）、Issue 详情 investigation 页签 | `agent_tools_test.exs`、`workbench_live_test.exs` | 实现并验证（真实 Agent 闭环 `blocked`） |
| R04 可追溯证据 | `Experience.Store`（journal + CAS blob）、`Query`、`Store.verify/1` | `store_test.exs`（不可变、哈希、故障注入、恢复演练） | 实现并验证 |
| R05 人类审阅与方向调整 | `Experience.Operations`（采纳/约束/暂停/恢复）、`ReviewsLive` | `operations_test.exs`、`workbench_live_test.exs` | 实现并验证（provider 侧真实切换 `blocked`） |
| R06 具体项目架构 | `Experience.Architecture`（发布验证、last-good、组件投影、过期判定）、`ArchitectureLive`、隔离 viewer | `architecture_test.exs`、`workbench_live_test.exs`、`docs/architecture/` 真实产物 | **部分**：机制与宿主自身架构产物已验证；受管产品源码图 `blocked`（无目标 repo revision） |
| R07 设备与真实观测 | `Devices.Manager`/`SerialPort`/helper、设备页、租约、隔离动作 | `manager_test.exs`、`serial_port_test.exs`、`workbench_live_test.exs` | **部分**：PTY 真实字节流已验证；真实板 `blocked` |
| R08 多模态与故障材料 | `Devices.Decoder`（匹配判定与受控解码） | `decoder_test.exs` | **部分**：不给假调用栈这条性质已验证；图像源与真机 dump `blocked` |
| R09 L0–L4 领域规则 | `docs/implementation/config/embedded-profile.yaml` 登记的 profile | profile 本身是配置；架构 manifest 对宿主代码不冒充分层 | **部分**：真实项目的技术绑定 `blocked` |
| R10 统一美术与可访问性 | `priv/static/workbench.css` Soft Glass tokens、双行壳、五页 | 页面结构与状态文字由 LiveView 测试断言；视觉验收 `blocked` | **部分**：token 与结构齐备，浏览器验收未做 |
| R11 异常与恢复 | Store 故障注入与恢复、索引重建、事件游标、孤立 blob 回收、动作隔离、页面降级 | `store_test.exs`、`manager_test.exs`、页面降级用例 | 实现并验证 |
| R12 可安装可运行交付 | `make release-assemble` 本机 release、`Store.backup/2` + 恢复演练、`docs/operations/` | `docs/verification/m5-release.md`：release 启动后六个路由 200 | **部分**：跨架构安装与 Burrito 打包 `blocked`（缺 zig/xz） |

## 关键场景

| 场景 | 状态 |
|---|---|
| J1 日常工作（看板→创建→Agent 执行→Review/Done） | 看板/创建/详情/状态回执已验证；真实 Agent 执行 `blocked` |
| J2 调查学习（ProblemCase→证据→方案取舍） | 读模型、证据穿透、方案取舍与限制已验证 |
| J3 掌控方向（选候选→采用→计划引用→恢复） | 采用、约束、暂停/恢复、计划摘要与恢复目标已验证；provider 侧真实生效 `blocked` |

## 为什么不能标「完整发布」

`docs/implementation/docs/ACCEPTANCE.md` 的 TC24 要求真实 Issue→Agent→目标板→证据→采用→
新 run→验证→Review/Done，且**缺一项真实 gate 都不能标完整发布**。本环境缺的正是这些真实
资源：

| 缺什么 | 影响 | 记录位置 |
|---|---|---|
| 可运行 Codex | 真实 Agent 执行与工程工具真实调用 | `docs/environment/environment.yaml` |
| 授权的 Linear 测试项目 | provider 真实读写与状态回切 | 同上 |
| 目标板与固件/ELF | 真机采集、真机 decoder、物理动作 | 同上 |
| 受管产品 repo revision | 受管产品的源码架构图 | 同上 |
| 可用的浏览器网络 | 视觉验收与架构产物的 `visual-check` | `docs/verification/m5-visual.md` |
| `zig` / `xz` | Burrito 自包含打包 | `docs/verification/m5-release.md` |

这些一律记为 `blocked`，没有用演示数据、PTY 或桩替代，也没有把「跑得动」写成「验证过」。

## 可复核的事实

- 分支上每个提交都经过 `make all` 全绿后才提交，提交信息由
  `docs/implementation/scripts/check_commit_message.py` 校验（`.githooks/commit-msg` 生效）。
- 真实产物：`docs/architecture/symphony-embedded-workbench/`（Archify `deliver` 退出 0，
  9/9 artifact checks，0 error/0 warning；`visual-check` 退出 1 并如实记为该状态）。
- 备份/恢复演练、release 启动、页面降级、解码器拒绝路径都有可重跑的测试或命令。