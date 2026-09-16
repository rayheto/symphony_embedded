# M3 项目架构（Archify 集成与架构页）— 交付记录

对应任务 T10–T11。状态按实测填写：未运行的项为 `not_run`，外部不可得的项为
`blocked`。本文件只记录 **实际执行** 的结果。

## 交付的纵向切片

| 能力 | 入口 | 状态 |
|---|---|---|
| 架构请求（按 revision 去重，映射到原 Issue 工作流） | `Experience.Architecture.request/3` | 实现并测试 |
| 交付验证与发布（文件、哈希、固定 skill 版本、回执） | `Experience.Architecture.validate_and_publish/3` | 实现并测试 |
| last-good 指针与失败尝试保留 | `Experience.Architecture.last_good/2`、`list_revisions/3` | 实现并测试 |
| 组件索引与工程记录投影 | `Experience.Architecture.component_index/2` | 实现并测试 |
| 过期判定（绑定 revision 比较，未知即未知） | `Experience.Architecture.staleness/2` | 实现并测试 |
| sandbox viewer 描述与受控产物端点 | `Architecture.viewer_descriptor/3`、`WorkbenchArchitectureController` | 实现并测试 |
| 架构页（版本、回执、组件索引、对比位、失败诊断） | `/workbench/architecture` | 实现并测试 |
| Agent 发布工具 | `engineering_architecture_publish` | 实现并测试 |

原 runtime 未改动：架构生成不进入 scheduler，`request/3` 只登记请求，生成仍由原 Issue
工作流上的 Archify 任务完成。

## 真实产物（宿主自身架构）

产物目录：`docs/architecture/symphony-embedded-workbench/`

| 文件 | 说明 |
|---|---|
| `source.architecture.json` | Archify 架构 IR，`meta.repository.revision` = `3600812f2e5a6d7bb2bd07676ceef7d57d0287e9` |
| `architecture.html` | `deliver` 产物（719,270 bytes） |
| `deliver.receipt.json` | deliver 回执：`ok: true`，9/9 artifact checks，0 errors / 0 warnings，来源核验 `verified: true`、10 条 references |
| `browser.receipt.json` | `visual-check` 回执：`status: "fail"` |
| `manifest.json` | 本产品独立 manifest：10 个组件（全部带 commit 绑定的 source_refs）、10 条来自 IR 的 relationships、4 条 limitations |

实际执行的命令（skill 根目录，固定版本 `a07fa1d5b2a10cbea110c5a2be2817397a301cdc`，metadata 2.17）：

```sh
node bin/archify.mjs doctor
node bin/archify.mjs validate architecture <candidate> --quality showcase --repo-root <repo>
node bin/archify.mjs deliver architecture <candidate> <output.html> --quality showcase --repo-root <repo> --json
node bin/archify.mjs visual-check <output.html> --json
```

`deliver` 退出 0；`visual-check` 退出 1。

该产物由本仓库自己的验证器复核：`test/symphony_elixir/experience/architecture_test.exs`
的 “the delivered platform diagram” 用例把这份 manifest 与三份文件重新上传并按同一套规则
发布，因此仓库里的字节是被规则约束的，而不是被描述为合规的。

## 已验证的行为

- **不信任调用方摘要**：manifest、IR、HTML 三份文件按哈希从 store 读回后逐项校验；缺失、
  哈希不符、IR 不是图、HTML 不是图都会拒绝。
- **固定版本**：`skill_commit` 必须是本 build 固定的 revision，其他 revision 一律
  `:unpinned_skill_commit`。
- **只引用真实存在的节点与边**：manifest 组件必须存在于随图交付的 IR；relationships 必须
  命中 IR 的 connection id 且端点、方向一致，凭空增加的边被拒绝。
- **来源可核验**：源码产物的每个 git source_ref 必须绑定该产物自己的 revision；计划图
  （设计材料）不得声称绑定已核验的 commit。
- **状态来自记录而非出图方**：`implementation_status` / `verification_status` 由 Issue 与
  Validation 记录重新计算。声称 `integrated`/`building` 而记录不支持、或声称 `passed` 而没有
  通过的 Validation 记录，都会**拒绝发布**而不是悄悄改写。
- **先落盘再回执**：被拒绝的发布不写 last-good，而是作为 failed 尝试保留诊断，页面同时显示
  last-good 与未被采纳的版本。
- **deliver 是验收门槛，浏览器证据是另一回事**：deliver 回执必须 `ok`、9/9 checks、
  0 error / 0 warning；browser / visual-review 回执按上游状态原样记录（`passed` /
  `failed` / `skipped` / `not_run`），失败不会被改写成“未运行”。
- **隔离承载**：产物端点不带 session/CSRF/应用壳，`sandbox="allow-scripts allow-downloads"`，
  默认 `?theme=light`，iframe 固定到页面标注的 revision（`&rev=N`），另有“独立打开”。
- **未知即未知**：没有登记运行绑定（`Binding.repo_revision`）时，过期状态显示“无法判断是否
  过期”，不会显示为“最新”。

## 未完成与阻塞

| 项 | 状态 | 原因 |
|---|---|---|
| 受管嵌入式产品自身的源码架构图（TC10 的目标含义） | `blocked` | 环境中 `project.repo_url` / `revision` 为空（`docs/environment/environment.yaml`）；没有真实目标 repo 与 revision 就不能产出源码图，也不以宿主源码冒充 |
| 计划图（plan） | `not_run` | 没有受管产品的设计材料来源可登记 |
| 对比图（delta） | `not_run` | 需要 base/head 两个真实 revision 的 Archify compare 产物 |
| 浏览器证据（TC11 的自动化部分） | `failed` | 该 artifact 的 HTML 引用 Google Fonts CDN；本环境的 Chrome 无法访问外部网络，`Page.loadEventFired` 15s 超时。按上游规则，运行时/采集失败不得改写成 `skipped`，也不影响已成功的 deliver |
| 独立视觉审阅（TC17 的感知部分） | `not_run` | 需要人或有读图能力的审阅者实际看图 |
| 真实 Agent 闭环发布 | `blocked` | 环境中没有可运行的 Codex（`docs/environment/environment.yaml`） |

浏览器证据失败的复现：同一条命令在本环境必定超时；把 HTML 中的两条 `fonts.googleapis` /
`gstatic` `<link>` 去掉后同一浏览器 0.5s 内完成渲染。这属于执行环境网络限制，不是产物缺陷，
但也不据此声称浏览器证据通过。

## 门禁证据

命令：`cd elixir && make all`（退出码 0）

| 步骤 | 结果 |
|---|---|
| `mix format --check-formatted` | 通过 |
| `mix specs.check` | 通过 |
| `mix credo --strict` | 0 issues |
| `mix test --cover` | 788 tests, 0 failures, 6 skipped, 100.00% |
| `mix dialyzer` | Total errors: 0 |

新增/修改的测试：

- `test/symphony_elixir/experience/architecture_test.exs`（69 tests）
- `test/symphony_elixir/experience/agent_tools_test.exs`（新增 `engineering_architecture_publish` 组）
- `test/symphony_elixir_web/workbench_live_test.exs`（新增 architecture page 组）