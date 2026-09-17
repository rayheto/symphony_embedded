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

### 监听地址与局域网访问

默认 `server.host: "127.0.0.1"`，只有本机能访问。要让同网段访问，把 host 改成本机地址或
`0.0.0.0`，再重启：

```yaml
server:
  port: 4123
  host: "0.0.0.0"        # 所有 IPv4 接口；也可以只写一个地址，如 "192.168.100.254"
```

```sh
ss -ltn | grep 4123                                    # 应显示 0.0.0.0:4123
curl -sI http://192.168.100.254:4123/workbench/issues | head -1
```

- `0.0.0.0` 覆盖所有接口（有线/无线/tailscale/网桥），**同时仍然服务 `127.0.0.1`**，所以
  frpc 之类的本地转发不受影响；只写某一个地址则只有该接口可达。
- **工作台没有鉴权**，而且 `config/config.exs` 里是 `check_origin: false`：能访问到该端口的人
  就能读全部记录，也能触发页面上的写操作（新建 Issue、开始采集等），跨站页面同样能与
  `/live/websocket` 完成握手。绑 `0.0.0.0` 之前先确认这就是你要的暴露面，必要时用防火墙把
  来源限制到固定网段。

### 演示与真实

| 模式 | 触发 | 说明 |
|---|---|---|
| demo | `workbench.mode: "demo"` | 演示 provider；页面显示「演示数据」，不会冒充真实 Issue |
| live | `workbench.mode: "live"` | 走宿主 tracker client；需要该 provider 的凭证 |
| files | `workbench.mode: "files"` | 读工程自己仓库里的记录，**只读**；不需要 tracker 账号，见下 |

缺凭证时不会回退到演示数据：`/workbench` 会说明工作台或 provider 不可用。

### 工程自有记录（files 模式）

有些工程没有 tracker 账号，工程真值就是仓库里的文件：每个任务一个 `task.md` / `handoff.md`，
加上子任务桥接写在旁边的 JSON。这类工程把 provider 指到这些文件上，工作台只读它们：

```yaml
workbench:
  enabled: true
  mode: "files"
  project_id: "open-cube"
  data_root: "/home/seeed/.local/share/symphony/open-cube-emb/data"
  record_root: "/home/seeed/rust-emb/open-cube/ref/agent/runs"
  bridge_tasks: "/home/seeed/.codex/agent-bridge/tasks"   # 可选：桥接目录
  bridge_task_marker: "rust-emb/open-cube"               # 可选：只认提到该串的任务
```

启动这套配置的方式与别的实例一样：

```bash
SHOT_WORKFLOW=/path/to/WORKFLOW.md mix run --no-start --no-halt scripts/workbench_server.exs
```

- 能力只有 `read`。创建 Issue、评论、改状态、暂停/恢复、workpad、原生链接全部**显式拒绝**
  （`unsupported_capability`，拒绝理由随回执返回），工作台不往工程仓库里写任何东西；
- 一条记录的状态是**记录自己的判词**（`complete` / `partial` / `blocked` / `failed` …）；写了
  判词外的词或根本没写判词的记成 `delivered`（待审阅），不替它升级成通过；
- Issue 一律 `dispatchable: false`：派发仍由 `tracker:` 决定，看板只是这些记录的投影；
- 桥接目录是多工程共用的，`bridge_task_marker` 用来只认本工程的任务；不给 marker 就不过滤，
  别的工程的任务也会上来。

`record_root` 下的 id 归属按目录决定：

| 形态 | 例子 | id 来自 |
|---|---|---|
| 根目录下的文件 | `t2.task.md`、`t2.handoff.md` | 标题里的 id，或文件名前缀 |
| 目录里有裸文件名 | `t1/task.md`、`t1/handoff.md` | 目录名（handoff 文件名漂了也算这条） |
| 目录里只有带名字的文件 | `family/a1.task.md` | 每个文件自己的名字 |

最后一行是有意的：容器目录（一个目录放几十个任务）不会把几十条记录并成一条。

`data_root` 不要放在 `/tmp` 下——它存的是工程记录，重启会把 `/tmp` 清掉。要把外部材料
（验收报告、门禁素材、会话节选）一次性录进工作台，用
`scripts/import_open_cube_acceptance.exs`：它先把素材按哈希复制成 blob（原件丢了也还在），
再写 Evidence / ProblemCase / Validation，并在写入前按 `priv/workbench/agent-tools.json`
逐条校验；复核不通过就中止导入，不落一份和当下事实不符的结论。

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

- 浏览器侧验收：截图与像素/对比度评审**已经做过**（`docs/verification/m5-visual.md`）；仍然没做的是
  **键盘走查**与 1280 / 1920 两个宽度的回归（同文件第十一节）。
- 本文件此前记过的两条已作废，别再照着读：「浏览器验收在本环境做不了」和「Archify 的
  `visual-check` 同样失败」。真正的原因是所有导航卡在 cookie 持久层等 keyring 不返回，
  加 `--password-store=basic` 即可；`browser.receipt.json` 现在是 `ok:true` / `status:pass`，
  旧的「字体 CDN 超时」归因也已撤回（`docs/verification/m3-architecture.md`）。
- 没有接入真实目标板，也没有可用的 Codex 与 Linear 测试项目；相关 gate 记为 `blocked`，
  没有用 PTY/演示数据代替（`docs/environment/environment.yaml`）。
- Burrito 打包（`make release`）需要 `zig` 与 `xz`；本环境没有，只有
  `make release-assemble` 的产物被实际启动验证过。
- 跨架构安装（arm64）未验证。