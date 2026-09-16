# M1 工作台任务闭环 — 交付记录

对应任务 T03–T05。状态按各验收项实测填写，未运行的项为 `not_run`，外部不可得的项为
`blocked`。本文件只记录 **实际执行** 的结果。

## 交付的纵向切片

| 能力 | 入口 | 状态 |
|---|---|---|
| 不可变工程记录存储（journal + 内容寻址 blob） | `Experience.Store` | 实现并测试 |
| 工作台读模型（快照/看板/详情/事件游标） | `Experience.Query` | 实现并测试 |
| provider 边界（Linear 与 Demo 两个实现） | `Experience.WorkbenchAdapter` | 实现并测试 |
| 类型化操作与回执 | `Experience.Operations` | 实现并测试 |
| 两行壳 + Issues 看板/列表 | `/workbench/issues` | 实现并测试 |
| Issue 详情四页签 | `/workbench/issues/:identifier` | 实现并测试 |
| 工作台子树 | `Experience.Supervisor` | 实现并测试 |
| Soft Glass v1.0 样式 | `priv/static/workbench.css` | 实现 |

原 runtime 未改动：`/`、`/api/v1/state`、`/api/v1/refresh`、`/api/v1/:issue_identifier`
保持原路由与行为。

## 门禁证据

命令：`cd elixir && make all`

| 步骤 | 结果 |
|---|---|
| `mix format --check-formatted` | 通过 |
| `mix specs.check` | 通过（所有 public `def` 均有 `@spec`） |
| `mix credo --strict` | 0 issues |
| `mix test` | 558 tests, 0 failures, 6 skipped |
| `mix test --cover` | 100.00% |
| `mix dialyzer` | Total errors: 0 |

完整输出：`docs/verification/evidence/make_all_m1.log`。

## 已实现并可复核的行为

- **单写入者、先落盘后确认**：`Store.append/7` 在返回成功前 fsync 日志；写入失败返回
  结构化错误，不谎报成功。
- **修订 CAS 与幂等**：`expected_revision` 不匹配返回 `:revision_conflict` 且不写入；
  同一 idempotency key 的相同请求返回同一 Operation，不同内容返回
  `:idempotency_conflict`。
- **日志完整性**：尾部不完整记录被截断并生成恢复报告；中段校验失败视为读故障，停止
  该项目的写入且不截断历史。
- **data root 约束**：必须为绝对路径且不在 `workspace.root` 内，配置期即拒绝。
- **显示映射不是第二份工作流**：原生状态仍归 tracker；未识别状态落到「其它」列并保持可见。
- **写入回执**：`received → applying → applied | failed | conflict | outcome_unknown`；
  只有未确认的结果才提示「先对账、不要重发」，确认失败提示「可修正后重试」。
- **表单草稿**：创建与评论的输入保存在 socket，被拒绝的提交不丢输入。
- **降级**：store 不可读时详情页仍显示 provider 侧的 Issue，工程区块诚实留空。

## 本切片发现并修复的原仓库缺陷

1. `~r/\R/` 缺少 `u` 标志，会把裸字节 `0x85` 当换行；「待」的 UTF-8 编码是
   `E5 BE 85`，因此任何含该字符的 WORKFLOW.md 字段都会被拆坏并导致配置回退到
   last-good。修复见 commit `fix(workflow)`，含回归用例。
2. 三个 retry 计时用例使用真实 Linear 端点启动 Orchestrator，网络往返落进墙钟断言窗口，
   基线 HEAD 上 `make all` 因此失败。修复只固定 tracker 为内存实现，断言阈值未改。
   详见 `m0-baseline.md`。

## 与验收规格的差距（诚实清单）

| 需求 | 现状 | 缺口 |
|---|---|---|
| R01 | 原 core 套件全绿、路由未变 | TC01 的 supervision 故障注入与 API 结构对比未做 |
| R02 | 看板/列表/筛选/创建/详情/回执均可用 | 真实 Linear 项目未提供，TC03 为 `blocked` |
| R03 | 调查页可读 Case/证据/实验/假设 | 无 Agent 上报工具（`Experience.AgentTools`），数据只能由宿主写入 |
| R04 | 证据存储、绑定、限制、审阅状态可查 | 无 UI/Agent 侧的证据登记动作；blob 上传入口未接 |
| R05 | 评论与要求补充证据产生耐久回执 | 采用方案/暂停/恢复/约束调整未实现 |
| R06 | 未开始 | Archify 集成、架构页、manifest 均未实现 |
| R07 | 未开始 | 设备管理、串口 helper、租约均未实现 |
| R08 | 未开始 | 图像源与 dump 解码未实现 |
| R09 | profile 模板在 `config/embedded-profile.yaml` | 代码侧 L0–L4 绑定未实现 |
| R10 | 壳与 Issues 页按 Soft Glass 实现 | 架构/设备/审阅页未实现；未做 1440×900 截图与对比度实测 |
| R11 | store 重启/修复/降级可验证 | 跨重启的持久暂停未实现（无暂停） |
| R12 | 未开始 | `make workbench-*` 目标、发布包、运维手册均未实现 |

## 真机与真实服务的可验证性

本环境没有 Linear 测试项目、可启动的 Codex 与目标板（见
`docs/environment/environment.md`）。因此：

- Linear 适配器通过注入的 GraphQL 客户端做契约测试，未对真实端点调用；
- 设备/审计/真机相关 gate 全部为 `blocked`，不以 PTY 或 Demo 顶替；
- Demo 模式的面板横幅始终可见，且写明不代表真实设备、实验或执行回执。

## 复现方式

```sh
cd elixir
make all                       # fmt / lint / specs / coverage / dialyzer
mix test test/symphony_elixir_web/workbench_live_test.exs
```

工作台需要 WORKFLOW.md 中存在启用的 `workbench` 段；示例见
`docs/implementation/config/`。未配置时 `/workbench/issues` 明确显示未启用并给出回到
runtime 的入口。