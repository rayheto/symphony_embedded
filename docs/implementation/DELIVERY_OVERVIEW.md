# Symphony Embedded 实施交付说明 — Soft Glass更新

更新日期：2026-09-15。保留Symphony Soft Glass v1.0视觉基线，新增明确的commit/push/PR/合并执行规范。

这是一套供 Coding Agent 实施的软件交付契约：基于现有 Symphony Elixir/Phoenix/LiveView，完整接受原 SPEC 的编排理念，扩展人类审阅、工程证据、具体项目架构与设备观测。当前交付的是实施文件，不是已经实现的应用。

## 包含什么

| 类别 | 文件/目录 | 固定什么 |
|---|---|---|
| 起点与任务指令 | START_HERE.md、IMPLEMENTATION_GOAL.md、AGENTS.md | 阅读顺序、实施目标、不可偏移项、Agent交付规则 |
| 目标与理念 | PRD.md、SPEC.md、TECHNICAL_WHITEPAPER.md | 12项产品需求；原SPEC全文+Appendix B；技术路线 |
| 原文与来源 | upstream/、sources.lock.json | 原SPEC逐字节快照、上游规则/工作流、仓库及Archify版本 |
| 边界与行为 | docs/ARCHITECTURE.md、DOMAIN_MODEL.md、STATE_AND_CONSISTENCY.md、INTERNAL_CONTRACTS.md | 数据权威、L0–L4中立边界、操作一致性、模块接口 |
| 机器契约 | contracts/、docs/API_CONTRACT.md | OpenAPI 3.1、实体Schema、设备JSONL、7项Agent工具、架构manifest |
| 交互与美术 | docs/INTERACTION_SPEC.md、UI_ACTIONS.md、VISUAL_SPEC.md、design/ | 全部按钮去向、异常态、Soft Glass完整指引包与四张单页预览、字体/颜色/间距tokens |
| 架构生成 | docs/ARCHIFY_INTEGRATION.md、prompts/archify-*.md | 使用固定Archify skill生成具体源码图、比较图与验收回执 |
| 设备与证据 | docs/DEVICE_EVIDENCE.md、config/ | 串口/图像/dump、租约、真实构建绑定与环境模板 |
| 可运行分阶段交付 | docs/IMPLEMENTATION_PLAN.md、planning/tasks.json | M0–M5六阶段、18项依赖明确的任务 |
| 验收与追踪 | docs/ACCEPTANCE.md、planning/traceability.csv、test-catalog.json | 24个验收场景；需求→任务→测试→实际证据 |
| 演示与测试输入 | fixtures/ | 附件八张Issue卡、两组原始日志、方案/设备/回执及契约样例 |
| 安装与报告 | docs/OPERATIONS.md、templates/、VALIDATION_REPORT.md | 干净环境、真实集成、备份恢复、发布报告 |
| 自检与完整性 | scripts/、requirements-validation.txt、MANIFEST.sha256 | Schema/接口/样例/追踪/哈希检查，合并SPEC同步 |

## 已固定的实现方向

1. 保留原scheduler/runner/retry/reconciliation/workspace语义；Issue原生状态仍归tracker，Orchestrator仍是唯一调度权威。
2. 原runtime首页和API继续保留。工作台入口为 `/workbench/issues`，顶部两行导航包含Issues、项目架构、设备、审阅记录。
3. 实现状态、验证状态、Agent判断和人类审阅分开。采用方案、工作流更新、新Agent读到计划、验证通过都有独立证据与回执。
4. 架构图使用Archify skill。提示词、版本、来源绑定、manifest与验收规则已提供；实际项目图在目标源码与revision确定后生成，不能用固定五层模板冒充。
5. 当前视觉基线为2026-09-15选定的Soft Glass v1.0：15px正文、28px标题、10/16/20px圆角、克制蓝色主动作，轻磨砂仅用于导航；顶部双行导航与无侧栏保留。新包18个原始文件完整收入，架构宿主页同风格。
6. 首版真实写入适配Linear，保留原其它provider能力；真实目标板由M0登记。Demo与PTY可以推进开发，但不能代替最终真机验收。

## 如何开始

解压完整包，把 `symphony-implementation-pack/` 内的内容放入目标仓库 `docs/implementation/`，保留内部相对路径。不要直接覆盖仓库根目录SPEC或AGENTS。让Coding Agent从START_HERE.md阅读，然后执行IMPLEMENTATION_GOAL.md。

你可以先审阅 PRD → SPEC Appendix B → 状态与一致性 → 交互/控件映射 → 验收 → 实施计划。一般内部实现细节交给Agent；核心语义、目标或公共契约的实质变化需要留明确决定记录。

本次已通过实施包的结构、Schema、接口一致性、演示样例、追踪关系和负向输入检查。软件测试、实际Archify产物、真实Agent/设备验证均留给实施阶段，状态为not_run。

本次替换的细节和新旧参数对照见包内 `docs/DESIGN_UPDATE_SOFT_GLASS.md`，视觉入口为 `design/README.md`。四张单页预览位于 `design/soft-glass/previews/`。

Git规则入口：`docs/GIT_WORKFLOW.md`。标题强制 `type(scope): 描述`，提交前检查通过自动commit；push前原make all与适用gate通过后自动推任务分支；自动维护Draft/Ready PR；人类Merging或已有合并授权后遵循land。检查脚本与hook样例已提供，目标仓库CI接入由M0实施，不能误认为已安装。
