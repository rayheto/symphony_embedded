# Symphony Embedded 运维说明

面向把这一版跑起来、备份、恢复和排查的人。所有命令都在 `elixir/` 下执行，除非另有说明。

## 环境

| 组件 | 版本 |
|---|---|
| Erlang/OTP | 28.5 |
| Elixir | 1.19.5-otp-28 |
| Node（仅 Archify 出图用） | 18+ |
| Python（设备 helper） | 3.9+，只要 `python3` 在 PATH 上 |

`mise.toml` 固定了 Erlang/Elixir 版本；`mix.lock` 固定依赖。

```sh
mise install          # 按 mise.toml 装 Erlang/Elixir
cd elixir && mix deps.get && mix build
```

`make all` 是原项目的门禁（格式、spec 检查、credo、覆盖率 100%、dialyzer），跑它就知道这棵
树是不是健康的。

## 运行

工作台是**加法**：`/`、`/api/v1/*` 仍是原来的运行视图，工作台在 `/workbench`。

### 本地开发

```sh
cd elixir
SHOT_WORKFLOW=/path/to/WORKFLOW.md mix run --no-start --no-halt scripts/workbench_server.exs
```

`--no-start` 是必要的：workflow 路径必须在应用启动前设好，否则 `WorkflowStore` 会去读当前
目录里的 `WORKFLOW.md`。

### 发行版

```sh
cd elixir
make release-assemble          # 本机可运行的 release 目录
# 或 make release               # Burrito 打包，需要 zig 与 xz
```

```sh
cd /path/to/workflow-dir       # 目录里要有 WORKFLOW.md
/path/to/rel/symphony/bin/symphony start
```

CLI 默认读当前目录的 `WORKFLOW.md`，也可以显式给路径：
`bin/symphony start`（release 形态）或 `bin/symphony <WORKFLOW.md>`（Burrito CLI 形态）。

### 演示与真实

| 模式 | 触发 | 说明 |
|---|---|---|
| demo | `workbench.mode: "demo"` | 演示 provider；页面显示「演示数据」，不会冒充真实 Issue |
| live | `workbench.mode: "live"` | 走宿主 tracker client；需要该 provider 的凭证 |

缺凭证时不会回退到演示数据：`/workbench` 会说明工作台或 provider 不可用。

## 数据

`workbench.data_root` 必须是一个绝对路径，且**不能在 workspace 根之内**——否则清理一个
workspace 就可能删掉证据。启动时校验，不满足就不启动工作台子树（调度器照常运行）。

```
<data_root>/
  store.lock                        当前写入者标识（不属于数据）
  projects/<project_id>/records.jsonl   追加写日志，唯一真值
  blobs/sha256/<前两位>/<digest>        内容寻址原件，写完不可改
  blobs/tmp/                           写入中的临时文件
```

- 记录先落盘（fsync）再回执；写失败返回结构化错误，不谎报成功。
- 同一个 data_root 只允许一个写入者：第二个进程拿到 `:data_root_locked` 并带持有者信息。
- 索引只是派生数据，可以重建；重建不会重新编号 `project_seq`。

## 备份与恢复

备份就是**复制 data root**，但不要带上锁文件和 `blobs/tmp`：

```elixir
{:ok, backup} = SymphonyElixir.Experience.Store.backup("/backup/symphony-data")
# %{"target" => ..., "files" => n, "bytes" => n, "excluded" => ["store.lock", "blobs/tmp"]}
```

恢复后先验证，再把它当作数据用：

```elixir
{:ok, report} = SymphonyElixir.Experience.Store.verify(server: restored_store)
# %{"ok" => true, "projects" => [%{"project" => ..., "seq" => n, "reports" => []}], "blobs" => %{"checked" => n, "corrupt" => [], "unreadable" => []}}
```

`verify/1` 只读：它会重放每个 journal、重算每个 blob 的摘要，报告它发现的东西，不做修复——
修复是决定，不是检查。`docs/verification/m4-hardening.md` 记了这条链路的测试。

要点：

- 恢复出来的副本里，记录、哈希和 blob 必须和原件一致；
- 带上了 `store.lock` 的副本会在恢复到的机器上拒绝启动（锁上有持有者标识），`backup/2` 已经
  把它排除；
- 恢复后 `rebuild_index/2` 可以用日志字节重建索引，不会重编号。

## 升级

- 契约 `schema_version` 为 `1.0`。未知的更高版本会被拒绝写入并要求升级，不做降级猜读。
- 先备份，再换版本；只迁移工程数据，不改写 blob 或历史记录的含义。
- 孤儿 blob（没有任何记录引用）可以用 `Store.orphan_blobs/1` 列出、用 `Store.reclaim_blobs/2`
  回收。回收只删被点名的 digest，删除前会重建引用集合；journal 读不出来时报
  `:journal_unreadable`，不会把「证明不了无人引用」当成「无人引用」。**原件不会被自动删除。**

## 降级行为（出问题时会怎样）

| 情况 | 表现 |
|---|---|
| 工作台没启用 | `/workbench` 说明未启用；调度器不受影响 |
| data_root 不合法 | 工作台子树不启动并记日志；调度器不受影响 |
| Store 停掉 | 页面显示「无法读取」而不是空列表；采集与调度不受影响 |
| 设备管理未运行 | 设备页说明清单读不到；其它页面不受影响 |
| Archify 生成失败 | 保留上一版 last-good，并显示尝试版本与诊断 |
| 动作结果未知 | 非幂等动作进入隔离，先 `probe` 才能再动（见 `docs/verification/m4-hardening.md`） |

## 已知限制

这些是**没有**验证过的部分，不要当成通过：

- 浏览器侧验收（截图、对比度、键盘走查）在本环境做不了：Chrome 无法完成需要建立连接的页面
  加载。见 `docs/verification/m5-visual.md`。
- Archify 的 `visual-check` 同样失败（`docs/verification/m3-architecture.md`）。
- 没有接入真实目标板，也没有可用的 Codex 与 Linear 测试项目；相关 gate 记为 `blocked`，
  没有用 PTY/演示数据代替（`docs/environment/environment.yaml`）。
- Burrito 打包（`make release`）需要 `zig` 与 `xz`；本环境没有，只有
  `make release-assemble` 的产物被实际启动验证过。
- 跨架构安装（arm64）未验证。