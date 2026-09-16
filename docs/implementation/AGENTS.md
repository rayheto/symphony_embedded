# Coding Agent 执行契约

本文件作用于本实施包的任务，不覆盖目标仓库原有指令。先读 START_HERE.md 与 IMPLEMENTATION_GOAL.md，再按阶段读取关联文档，不要求每个子任务重复加载全部历史。

- 尽量全盘接受原SPEC理念与行为；不能以重构、美术或多Agent为理由另建调度权威。
- 视觉合同为Symphony Soft Glass v1.0，见design/soft-glass中的guide/tokens/CSS及docs/VISUAL_SPEC.md；业务提示词仅固定字段、状态与动作。旧14px正文/小圆角/深灰主按钮不再适用，不因源文件保留旧段落而混用。
- 项目架构必须使用Archify skill+本包prompts，检查真实repo revision。没有实现来源就标计划/未生成，不画虚假“具体已完成”架构。
- 普通实现决定自主完成，持续推进到可运行、可验证交付；用户不需读每个handoff。
- 涉及公共状态权威、core语义、用户目标或公共接口的偏离先形成具体ADR/diff与证据，必要时只暂停受影响工作。缺权限/设备不编造，不删除需求蒙混验收。
- 一次任务先确认输入来源、允许路径、依赖、验收TC。目标项目L0–L4不是本平台前后端的文件划分。
- 使用subagent时共享此约束、限定文件owner、遵循已有协调机制；默认不为每层建立永久Agent或新队列。handoff使用templates/handoff.md。
- 实际状态写回原workpad/阶段报告，不能以“代码已写”标完成。claim、validation、human review分开。
- 更改契约同步schema、fixture、tests与文档；同一PR含必要行为说明。遵守原elixir所有public def相邻@spec、make all等规则。
- 原审批/sandbox姿态保留，以实际环境授权为准；不能因工作台新增一刀切审批，也不能绕过宿主权限。
- 关键验证含真实OTP/外部边界和失败恢复；mock只能隔离依赖。不能把缺工具的not_run/skipped改为pass。
- 不降低原coverage/静态检查阈值逃避gate；非平凡变更做对抗性review并复现问题。
- 任何截图/日志/sample必须标来源和是否demo；不能生成假的运行截图、设备结果或人类签字。
- 原始证据不随workspace清理，敏感信息不出现在日志或浏览器。源码/文档不存在不能根据路径名补造内容。
- Git执行规范必须遵循docs/GIT_WORKFLOW.md与planning/git-policy.json：标题type(scope): 描述（72字符内）；连贯切片通过提交前检查后自动commit，push前保留原make all与相关gate，通过后仅推任务分支并维护Draft/Ready PR。合并须有原工作流人类授权，Merging后使用land；不自行制造批准、不force push。阶段编号不当产品版本；分支目标按本项目实际有效要求解析。
