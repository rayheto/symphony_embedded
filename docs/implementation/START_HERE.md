# Symphony Embedded 实施包

交付日期：2026-09-15（Soft Glass视觉更新）。性质：实施规范与交付契约，不是已完成的软件。用户授权编写本包；包内具体实现默认值是本次设计决定，不虚称用户逐项签字批准。

## 从这里开始

将整个目录放入目标仓库 `docs/implementation/`，保持内部相对路径。不要用本目录的文件直接覆盖仓库根目录文件。
让 Coding Agent 执行 [IMPLEMENTATION_GOAL.md](IMPLEMENTATION_GOAL.md)。阅读根目录 [AGENTS.md](AGENTS.md) 时同时遵循目标仓库已有 AGENTS.md，尤其 `elixir/AGENTS.md`。本包只补充任务约束，不取消原规则。

1. 阅读 [PRD.md](PRD.md)、[SPEC.md](SPEC.md)、[TECHNICAL_WHITEPAPER.md](TECHNICAL_WHITEPAPER.md)。
2. 阅读 [架构](docs/ARCHITECTURE.md)、[领域模型](docs/DOMAIN_MODEL.md)、[接口](contracts/openapi.yaml)、[状态与一致性](docs/STATE_AND_CONSISTENCY.md)、[API语义](docs/API_CONTRACT.md)和[内部契约](docs/INTERNAL_CONTRACTS.md)。
3. 阅读 [交互](docs/INTERACTION_SPEC.md)、[美术](docs/VISUAL_SPEC.md)、[控件行为映射](docs/UI_ACTIONS.md)和用户提供的 [Soft Glass设计入口](design/README.md)。
4. 按 [实施计划](docs/IMPLEMENTATION_PLAN.md)和 [tasks.json](planning/tasks.json)逐阶段交付，以 [验收规格](docs/ACCEPTANCE.md)为准。
5. 执行 [Git提交与合并规则](docs/GIT_WORKFLOW.md)，按 [Git验收](docs/GIT_ACCEPTANCE.md)接入提交信息检查与现有CI。
6. 对照 [追踪矩阵](planning/traceability.csv)，提交实际执行的验证证据；最后按 [运行手册](docs/OPERATIONS.md)验证干净环境安装。

## 基线与不可偏移项

- 原仓库：rayheto/symphony_embedded，检查提交 `e0ccc83720a42a600a53b61c5f8d3e518bebe1db`。
- 原 SPEC SHA-256：`c6638056502ecd2e60eb04e1f1a627a4964506fcdf4d39873e78aa5834de85d5`。`upstream/SPEC.original.md` 保持逐字节一致。
- `SPEC.md` 是原 SPEC 原文加 Appendix B 的完整阅读版；Appendix B 从 [SPEC_EXTENSION.md](docs/SPEC_EXTENSION.md)生成，不可分别手改造成漂移。
- 原 SPEC 理念、调度/恢复行为整体接受。Issue 状态来自 tracker，Orchestrator 是唯一调度权威，工作流政策归仓库。
- 架构图必须通过 Archify skill 从具体项目来源生成。不得以固定 L0–L4 图、ImageGen 图片或自写图引擎替代。
- 最新视觉基线为Symphony Soft Glass v1.0：顶部双行导航、无大侧栏、系统无衬线、15px正文、28px标题、分级圆角、克制蓝色主动作、仅导航轻磨砂。业务原文保留字段与行为，旧视觉参数由新guide/tokens/CSS覆盖。
- L0–L4 是被开发的嵌入式产品边界，不是 Symphony Web 软件模块必须套用的五层。

## 文档权威按职责划分

用户最新明确要求优先。原 SPEC 定义核心语义，Appendix B 定义扩展；PRD 定义范围；Schema/API 定义数据契约；交互规格定义行为；Soft Glass guide/tokens/CSS定义视觉，随包业务提示词定义字段与静态样例；PNG只辅助审美。发生跨文档矛盾，登记冲突并修复最小范围，不能静默让图片或实现覆盖行为契约。无冲突部分继续推进。

## 能立即开展与需要环境才能完成的工作

立即开展：基线审计、实现、Demo/PTY 自动验证、真实源码 Archify 生成、浏览器验收。
真实发布前需要：一个可用 tracker 测试项目、可启动的 Codex、选定设备的串口与构建材料。缺失时应明确标为 blocked/skipped，不能编造通过。M0 记录实际值；不需要反复向用户确认一般实现细节。

## 包的检查

Python 3 环境安装 `requirements-validation.txt` 后运行：
```sh
python3 scripts/verify_pack.py
```
这只验证实施包完整性、Schema、示例、接口和追踪关系，不是产品测试。实际应用需要完成 `make all`、浏览器测试及真实集成测试。

原型中的设备/Issue/日志都在 `fixtures/demo.json`；它们是可视化演示数据，不是真实工程验证。最终发布不能停留在 Demo。
