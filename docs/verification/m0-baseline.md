# M0 基线报告（T01）

本文件记录原仓库在本次实施开始时的 **实际** 状态。所有结果绑定具体 revision；
没有执行的项目一律 `not_run` / `blocked`。

## 基线身份

| 项 | 值 |
|---|---|
| base branch | `main` |
| base SHA | `e0ccc83720a42a600a53b61c5f8d3e518bebe1db` |
| 与 `sources.lock` 声明一致 | 是（原包检查提交 `e0ccc837…`） |
| 工作分支 | `agent/embedded-workbench` |
| dispatch 权威 | 原 `SymphonyElixir.Orchestrator` 未改动 |
| 原 runtime 入口 | `/`、`/api/v1/state`、`/api/v1/refresh`、`/api/v1/:issue_identifier` 保留 |

## 工具链

`elixir/mise.toml` 锁定 `erlang = "28"`、`elixir = "1.19.5-otp-28"`。本次实测安装：
Erlang/OTP 28.5（erts-16.4）、Elixir 1.19.5。命令入口为 `cd elixir && make all`。

## 门禁结果

### 修改前（baseline HEAD，未改动任何文件）

命令：`make all`。结果 **失败**。

```
299 tests, 3 failures, 6 skipped
make[1]: *** [Makefile:27: coverage] Error 2
```

失败用例全部位于 `test/symphony_elixir/core_test.exs`，都是对 retry 调度时刻的
墙钟断言：

| 用例 | 断言 | 实测 |
|---|---|---|
| normal worker exit schedules active-state continuation retry | remaining ∈ [500, 1100] ms | 376 ms |
| first abnormal worker exit waits before retrying | remaining ∈ [9000, 10500] ms | 8563 ms |
| abnormal worker exit increments retry attempt progressively | remaining ∈ [39500, 40500] ms | 39395 ms |

**根因（已实测确认，非本次改动引入）**：这三个用例启动真实 `Orchestrator`，而
`test/support/test_support.exs` 的默认 workflow 把 tracker 指向真实
`https://api.linear.app/graphql`。Orchestrator 启动后立刻轮询该端点，网络往返
被计入 `Process.sleep(50)` 与 `:sys.get_state/1` 之间的墙钟窗口，使
`assert_due_in_range/3` 实测值系统性偏小。单独运行该用例文件可复现（2 次运行
均失败），与本机负载无关。

证据：
- `/tmp/m0/make_all_baseline.log`（完整输出，`EXIT=2`）
- 复现命令：`mix test test/symphony_elixir/core_test.exs:1022`（改前 2.3s，1 failure）

### 修复与修改后

修复只做一件事：在这三个用例里把 tracker 固定为内存 adapter
（`tracker_kind: "memory"`，与同文件其它用例一致），使被测窗口不再包含无关网络
I/O。**断言阈值与用例语义均未改动**，未放宽任何 limit，也未降低 coverage 阈值。

修复后：

| 命令 | 结果 |
|---|---|
| `mix test test/symphony_elixir/core_test.exs:1022` | 0.6s，1 test，0 failures |
| `make all` | **通过**：299 tests, 0 failures, 6 skipped；coverage 100.00%；dialyzer 0 errors |

证据：`/tmp/m0/make_all_fixed.log`（`EXIT=0`）。

## 新增模块后的门禁

在加入 `Experience.Canonical` / `Experience.Store`（T03）与 `workbench` 配置段后
重跑 `make all`：全部通过，新模块 coverage 100%，`mix credo --strict` 无 issue，
`mix specs.check` 通过。证据见 `docs/verification/` 下对应切片记录。

## TC01 状态

| 检查项 | 状态 | 说明 |
|---|---|---|
| 原 core 套件在禁用 workbench 时通过 | `passed` | 见上表；`make all` 全绿 |
| 原 API 字段兼容 | `passed`（结构对比） | `/api/v1/*` 路由未改动；工作台挂在 `/workbench` 与 `/experience/v1` |
| 未新增调度 owner | `passed` | 未新增 tick/dispatch；`Experience.*` 不持有 claim/running 状态 |
| UI 故障不影响 core | `passed` | 工作台在独立 subtree；Experience 写失败返回结构化错误，不改 retry 语义 |

`TC01` 的真实 HTTP 对照与 supervision 故障注入属于后续切片，见
`docs/verification/` 的阶段记录。

## 已知限制

- 真实 Linear 测试项目、可启动 Codex、目标板在本环境均不可得，相关 gate 为
  `blocked`（见 `docs/environment/README.md`），不以 PTY/Demo 顶替。
- `arm64_install` 在本机（x86_64）为 `blocked`。