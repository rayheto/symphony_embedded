# Commit、Push、PR 与合并执行规范

生效于本实施包后续编码任务。目标：连贯、可验证的提交历史；通过既有工作流自动推进，保留清晰的合并授权与证据。执行入口为 `AGENTS.md`；机器参数见 `planning/git-policy.json`。
本次交付只新增规范和检查工具，未对用户远端仓库进行commit、push、建PR或合并，也没有声称已安装Git hook/CI。

## 1. 提交标题：强制Conventional Commits项目约束

依据[Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)。官方scope可选；本项目进一步要求**每个人工/Agent编写的普通提交必须有scope**，type和scope小写，冒号后一个ASCII空格，完整标题不超过72个Unicode字符。中文描述优先，也允许清晰英文，不强制翻译代码名。禁止空描述、首尾空格、多行标题、WIP/fixup!/squash!临时标题。

```text
<type>(<scope>): <具体改动>
<type>(<scope>)!: <不兼容改动>
```

| type | 适用范围 | 示例 |
|---|---|---|
| feat | 新增用户/系统能力 | feat(issues): 新增任务看板与筛选 |
| fix | 修复错误行为 | fix(evidence): 修复证据版本关联错误 |
| docs | 仅文档 | docs(spec): 补充方案采用回执规则 |
| style | 格式、排版等不影响语义的代码整理 | style(elixir): 统一格式化结果 |
| refactor | 不改变对外行为的结构调整 | refactor(review): 统一方案采用操作入口 |
| perf | 性能改进 | perf(serial): 限制日志列表渲染批次 |
| test | 测试或测试数据 | test(devices): 增加串口断连恢复测试 |
| build | 依赖、构建、打包 | build(release): 纳入设备采集依赖 |
| ci | 持续集成配置 | ci(commit): 增加提交信息检查 |
| chore | 其它维护，不掩盖功能改动 | chore(tooling): 更新开发工具配置 |
| revert | 撤销已知提交 | revert(devices): 撤销有回归的采集策略 |

scope描述真实模块/能力，例如issues、investigation、evidence、review、architecture、devices、serial、runtime、workflow、api、ui、spec、release；可按模块增加，格式为小写kebab-case，不使用M1/M2作为scope。用户可见视觉功能用feat(ui)，修复视觉缺陷用fix(ui)，不能把所有CSS功能变化归style。
标题写具体行为，不写“更新代码”“完成M2”“修复一些问题”。Issue编号放footer，如 `Refs: EMB-42`；任务阶段放handoff，不能当产品版本。一个commit保持一个连贯目的，必要测试/文档随对应改动一起提交。

正文可省略；非显而易见的改动说明原因、行为和局限。标题后空一行才开始正文。真实检查证据放PR/workpad；可在正文简述，但禁止编造PASS。
不兼容变更在本项目同时要求标题`!`和非空 `BREAKING CHANGE: ...`（也接受官方同义 `BREAKING-CHANGE:`）footer，写清影响与迁移路径。打标不代表已获变更核心契约授权。

```text
feat(api)!: 将证据来源改为显式构建绑定

避免旧接口将不同固件的日志混为一组证据。

BREAKING CHANGE: 客户端须提交binding字段；按迁移说明补齐旧记录。
Refs: EMB-42
```

机器规则允许既有pull/land流程真正产生的多父merge commit保留Git合并标题；它们不是业务提交。校验器根据Git父节点跳过真实merge，不能用“Merge ...”文字绕过普通commit检查。历史base之前的提交不追溯重写。PR标题及squash落地标题仍必须是上述格式。

## 2. 分支与暂存范围

开工先读取实际仓库AGENTS、WORKFLOW、贡献规则，记录remote、base branch/base SHA、工作分支和已有用户改动。当前锁定上游WORKFLOW采用origin/main；若用户在本项目明确指定dev或仓库改为其它集成分支，则统一更新配置和PR base，不从其它项目的历史偏好猜。
base优先级：本次明确指令→仓库有效工作流/贡献规则→实际远端默认分支。前两者存在时不另猜main；来源冲突先保留工作并说明，不能擅自合并。
优先沿用当前Issue绑定且尚未closed/merged的任务分支及PR；否则从有效base新建 `agent/<issue-id-or-task-key>-<short-slug>`，如 `agent/emb-42-evidence-binding`。受保护分支不直接开发/直推；复用分支前确认不是他人并行占用。原workflow对closed/merged PR新开分支的规则保持。
逐文件/逐hunk暂存本任务改动；共享工作区禁止无检查`git add .`。已有用户改动不能覆盖、丢弃或混入自己的提交。不要用reset --hard、强制clean或静默stash来消除别人的改动。

## 3. 每次commit前必跑检查

每次提交前必须完成以下检查；同一代码内容的有效检查结果可复用，不反复执行无变化的完整测试。暂存内容改变、解决冲突或更新依赖后，重新执行受影响检查。

| 范围 | 提交前门槛 |
|---|---|
| 所有提交 | `git diff --check`、`git diff --cached --check`；检查status与staged diff，确认目的单一，无冲突标记、凭证、临时实验/生成垃圾或他人改动；检查提交标题/正文 |
| Elixir运行代码/测试/config | 在elixir目录运行`mix format --check-formatted`、`mix specs.check`和受影响`mix test <实际测试路径>`；状态性改动覆盖相关启动/reload/restart/失败恢复 |
| Experience接口/Schema/fixture | 跑`python3 docs/implementation/scripts/verify_pack.py`及受影响服务/adapter契约测试；修改受封包清单保护的文件先按第8节重建清单 |
| UI/样式/交互 | 相关LiveView/浏览器测试；视觉改变提供受影响页面1440×900截图对照及必要状态检查；不能只凭编译通过 |
| 设备helper/采集 | 受影响helper与PTY测试，检查raw bytes/断连/租约等实际改动风险；涉及真机行为按对应TC提交真机结果或明确blocked |
| 仅文档/说明 | 本实施包自检（若改本包）、本地链接/示例命令与引用核对；不为拼写修正新增无意义产品测试 |
| 依赖/构建/CI | 锁文件一致性、受影响构建/安装或CI命令实跑；平台缺失记录blocked，不能假PASS |

提交信息检查：
```sh
python3 docs/implementation/scripts/check_commit_message.py --file /absolute/path/commit-message.txt
```
禁止通过`--no-verify`或降低原测试阈值绕过门槛。失败先修复；确有外部阻塞，只保留尚未通过的工作区并记录原因，可继续提交其它独立、已经通过检查的切片。不得把已知失败的实现包装为普通完成commit。单纯文档记录阻塞可以独立docs commit。
检查必须对应真正提交的tree。未暂存实验可能影响结果时，用隔离工作树验证预期提交tree，不能声称工作区测试证明了另一份暂存内容。提交后记录SHA/tree与测试材料；无需为了在自身正文写自身SHA而反复amend。

## 4. 自动commit与push时机

**默认自动commit**：完成一个连贯、可运行/可验证切片，且第3节检查通过后，Agent立即本地提交，无需等整个阶段结束、也不逐commit向用户确认。不要每保存一个文件就提交，或积攒一个无法审阅的全项目commit。必要修复以新commit补上；默认不重写已发布历史。

**默认自动push任务分支**：一个计划任务/可审阅纵向切片完成，或需要更新已有PR处理反馈时，在以下门槛满足后push到已配置的同一项目远端。不是每个中间commit都push；不另加无必要人工确认。

1. 当前分支为该任务分支，remote/base已核对；仅推该分支，不`--all`、不直推main/dev/release等保护目标。
2. 所有待推送的新普通commit信息校验通过；推送对象为已验证commit，不把工作区未提交文件当远端成果。
3. 原仓库要求的交付gate通过。本项目每次push前执行/复用当前tree的 `make -C elixir all` 结果；再跑本切片适用的workbench/helper/UI契约检查。受影响真机gate未完成则不能将该能力标可验收；明确处于开发阶段的独立已验证切片可push并保持Draft。
4. 有PR时依原pull/workflow策略同步有效base、处理相关反馈；同步或冲突解决改变tree后重新检查。使用原仓库commit/push/pull skill（若存在/被工作流要求），不绕过其有效约束。
5. push采用任务分支正常快进更新。被远端并发更新拒绝时先fetch/比较并保留双方改动，不默认force或force-with-lease，不自动覆盖共享历史。

已有检查结果若绑定完全相同tree、依赖锁和相关环境，可在push前复用并记录；CI必须对应实际PR head。缺远端/凭证/网络/权限时保留本地commit并明确push blocked，继续不依赖发布的任务，不创建未知远端、不绕过权限。用户明确要求“不push”时仅本地提交；后续已有明确push授权持续有效，不反复询问。

## 5. PR创建、内容与进入审阅

第一次已push的可运行切片后自动创建Draft PR；若同一任务分支已有open PR则持续更新，不重复建PR。base必须是第2节已解析目标。原workflow若有更具体PR创建时点，遵守其有效流程。
PR标题采用相同Conventional Commits格式。正文严格采用仓库 `.github/pull_request_template.md`（本包保存上游快照供查阅）；不要用另一模板替换原必需标题。

- Context：为何需要；TL;DR：行为变化；Summary：实际实现与范围。
- Alternatives：考虑过的替代方案/取舍；不要填空泛套话。
- Test Plan：真实执行命令、结果、证据链接、未运行/阻塞及影响。勾选项只代表实际通过。
- 把相关Issue、R/TC、截图、兼容性/迁移和限制放入合适现有段落，不擅自改变模板结构。
- 按已有规则运行 `mix pr_body.check --file /absolute/path/pr-body.md`；shell发布时使用`--body-file`保持原始换行。不能把token、完整敏感日志或无关用户资料放入PR。

完成本PR范围、相关gate全绿、必要的非平凡对抗性审阅已处理、变更文档与证据齐全后才转Ready for review；Issue按原流程进入Human Review。此“对抗性审阅”不强制spawn subagent，按当前环境与授权执行。
Draft表示工作可见，不意味着阶段完成；Ready也不表示人类已批准合并。原workflow要求的PR反馈扫描继续执行；实质意见必须修复或给出有依据的解释，不能自动把未解决意见标resolved。

## 6. 合并与合并后

**不因CI绿色或自己生成的review自动合并。** 当前上游授权信号是人类将Issue移至`Merging`；已有明确会话合并授权或团队既定自动合并政策可按其范围执行，无需再次请求相同授权。Agent不能自行把Human Review改成Merging制造批准。

进入已授权Merging后，读取并执行 `.codex/skills/land/SKILL.md`及其land循环；这是原workflow明确要求，不直接调用`gh pr merge`取代它。skill不可用时报告具体缺失并保留可审阅PR，不自己发明替代合并动作。

合并门槛：base正确；无冲突；required CI对当前PR head通过；保护规则/必要review满足；相关反馈已处理；授权仍适用于当前变更。批准后若有新的实质行为/接口改动，应按原review政策重新进入审阅；纯同步base等是否使批准失效遵守仓库规则，不自行绕过dismissed approval。
合并方式遵循仓库/land既定策略；若没有规定且平台允许，默认squash，以符合规范的PR标题作为落地主标题。实际多父merge commit允许自动Git标题，不重写上游历史来满足普通提交格式。
合并成功后核对远端PR merged状态与实际merge SHA，更新原workpad/Issue到Done并附证据；不能只看本地命令退出0。分支清理仅在既定策略允许且无他人使用时进行。发布tag、部署、发布二进制另按已有授权/工作流处理，不把合并当自动发布授权。
没有合并授权时完成Ready PR与验证材料，继续独立任务；不能删除目标或反复逐commit索要同意。

## 7. 检查工具与落地

本包提供零额外依赖的Python提交信息检查器、可接入的commit-msg hook样例及自测。它们检查信息格式，不宣称能证明测试成功、授权或远端保护规则。

```sh
python3 docs/implementation/scripts/check_commit_message.py --self-test
python3 docs/implementation/scripts/check_commit_message.py --file /absolute/path/commit-message.txt
python3 docs/implementation/scripts/check_commit_message.py --repo /absolute/repository --range "$SYMPHONY_BASE_SHA..$SYMPHONY_HEAD_SHA"
```
最后一条只检查范围内的新普通commit，以真实Git父节点豁免merge；上游历史不纳入。CI必须用实际PR base/head对应的范围，不无差别扫描整个repo历史。PR标题用`--title-file`验证；若标题有`!`，迁移footer在最终commit/PR正文中另由完整信息检查和review确认。
M0/T01–T02必须接入：在已有hook链中增加检查或采用样例，不覆盖已有hook/core.hooksPath；现有CI增加commit range+PR标题检查，并纳入仓库必要检查。分支保护修改需要实际权限，权限缺失记录blocked，不虚称CI已强制。
Git/CI接入完成后，对有效标题通过、无scope/错误type/缺空格/超长/虚假Merge/破坏性缺footer拒绝进行实际验证；`--no-verify`即使可跳过本地hook也必须被CI拦截。远端CI必要检查与规则配置是否生效单独核对。

## 8. 修改本实施包的封包约束

本包MANIFEST.sha256用于交付完整性，不是永久禁止修改。编辑SPEC扩展后先运行sync_spec.py；修改其它文件后更新FILE_INDEX并运行refresh_manifest.py，再运行verify_pack.py --require-manifest。更新清单只是重新记录bytes，不能代替Schema、契约或行为验证。
本轮要求属于交付流程增强，不能因此扩大产品范围、改变原SPEC调度/审批状态机、或恢复旧视觉设计。Git规则与Soft Glass视觉规则同时有效。
