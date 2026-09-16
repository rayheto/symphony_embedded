# M5 可安装发行版与备份恢复（TC23 适用部分）— 交付记录

对应任务 T17。只记录 **实际执行** 的结果。跨架构安装与 Burrito 打包在本环境不可得，记为
`blocked`，不据此声称阶段完整。

## 交付内容

| 能力 | 入口 | 状态 |
|---|---|---|
| 本机 release 组装 | `make release-assemble` | 实现并实际启动验证 |
| Burrito 自包含打包 | `make release` | `blocked`（缺 `zig` / `xz`） |
| 工作台截图 | `make workbench-shots` | `blocked`（浏览器，见 `m5-visual.md`） |
| 备份（排除锁与临时文件） | `Store.backup/2` | 实现并测试 |
| 数据根校验（重放日志 + 重算 blob 摘要） | `Store.verify/1` | 实现并测试 |
| 恢复演练（备份→恢复到新根→校验→重建索引） | `store_test.exs` "verification and restore" | 实现并测试 |
| 运维说明 | `docs/operations/README.md` | 完成 |

## 实测：release 启动并服务全部路由

```sh
cd elixir
make release-assemble
# => _build/prod/rel/symphony/bin/symphony

cd /tmp/workflow-dir            # 目录里放 demo WORKFLOW.md（port: 4199）
/path/to/_build/prod/rel/symphony/bin/symphony start
```

启动后逐路由取状态码（`curl -o /dev/null -w '%{http_code}'`）：

| 路由 | 状态码 |
|---|---|
| `/workbench/issues` | 200 |
| `/workbench/architecture` | 200 |
| `/workbench/devices` | 200 |
| `/workbench/reviews` | 200 |
| `/` | 200 |
| `/api/v1/state` | 200 |

`/workbench/architecture` 的响应正文里出现了页面标题「项目架构」，说明是真实渲染而不是静态
壳。进程用 `bin/symphony stop` 正常停止。

说明：未打包的 release 用标准 release CLI（`start`/`stop`/`remote`），不解析 CLI 的位置参数；
它读**当前目录**的 `WORKFLOW.md`。Burrito 形态（`bin/symphony <WORKFLOW.md> ...`）在本环境
不产出，见下。

## 备份 / 恢复

`Store.backup/2` 把 data root 复制到目标位置，并**排除** `store.lock` 与 `blobs/tmp`：

- 锁文件上有持有者标识，带进副本会让副本在被恢复的那台机器上拒绝启动；
- `blobs/tmp` 是写入中的临时文件，不是数据。

`Store.verify/1` 只读地重放每个 project 的 journal 并重算每个 blob 的摘要：

```elixir
{:ok, report} = Store.verify(server: store)
# %{"ok" => bool, "projects" => [%{"project" => id, "seq" => n, "reports" => [...], "ok" => bool}],
#   "blobs" => %{"checked" => n, "corrupt" => [...], "unreadable" => [...]}}
```

测试覆盖：干净数据根通过；被改写的 blob 报 `corrupt` 并给出现值；打不开的 journal 报
`journal_unreadable` 而不是当成空项目；备份落在数据根之内被拒绝
（`:backup_inside_data_root`）。

恢复演练（`store_test.exs`）：写入两条记录 + 一个 blob → `backup/2` 到新目录 → 在新目录上起
一个 store → `verify/1` 通过 → 读回最新修订（`entity_revision` 2、`project_seq` 与原件一致）
→ 读回归档修订并比对 `payload_sha256` → 读回 blob 字节完全一致 → `rebuild_index/2` 后
`project_seq` 仍是 2。

## 未完成与阻塞

| 项 | 状态 | 原因 |
|---|---|---|
| `make release`（Burrito 自包含包） | `blocked` | 缺 `zig` 与 `xz`；`mix release` 在 assemble 后于 `Burrito.wrap` 退出 1，错误原文见下 |
| arm64 / 其它平台安装 | `blocked` | 本机是 x86_64；交叉目标由 Burrito 负责，未产出 |
| 干净环境的完整安装演练 | `not_run` | 只有本机 release 启动验证；没有第二台干净机器可用 |
| 浏览器侧验收 | `blocked` | 见 `m5-visual.md` |

Burrito 失败原文：

```
> You MUST have `zig` and `xz` installed to use Burrito, we couldn't find all of them in your PATH!
** (exit) 1
    (burrito 1.5.0) lib/burrito.ex:36: Burrito.pre_check/0
```

为了让本机 release 可用，`mix.exs` 的 release 步骤在 `BURRITO_SKIP_WRAP=1` 时只做 `assemble`；
默认行为（含 Burrito 打包）未改变，`make release` 仍走原来的路径。

## 门禁证据

命令：`cd elixir && make all`（退出码 0）

| 步骤 | 结果 |
|---|---|
| `mix format --check-formatted` | 通过 |
| `mix specs.check` | 通过 |
| `mix credo --strict` | 0 issues |
| `mix test --cover` | 100.00% |
| `mix dialyzer` | Total errors: 0 |