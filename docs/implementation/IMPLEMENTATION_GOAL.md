# 给 Coding Agent 的完整实施指令

在 `rayheto/symphony_embedded` 的现有Elixir实现基础上，按本实施包完成可运行、可测试的 Symphony Embedded 工作台。目标是完整交付R01–R12，包含真实Issue/Agent/设备证据链，不停留在文档、静态界面或mock演示。

先完整阅读本包START_HERE、AGENTS、PRD、SPEC（包含Appendix B）、TECHNICAL_WHITEPAPER，以及仓库已有AGENTS和elixir/AGENTS。核对当前HEAD与sources.lock基线差异，保留用户现有改动，不盲目覆盖。

按planning/tasks.json和IMPLEMENTATION_PLAN逐阶段实施。架构、领域和状态/接口按docs与contracts；UI先读design/README.md，按Soft Glass guide与design/tokens实施；业务字段仍按随包Symphony-design-prompt.md。15px正文、28px标题、10/16/20px分级圆角、蓝色主动作、仅导航轻磨砂；两行顶部导航与无侧栏保留。架构页面使用Archify skill生成真实项目图，具体执行prompts/archify-project.md，不自行写图形引擎。

M0先跑原基线并登记环境，选择可用的真实Linear测试project和目标板适配（用户未提供的端口/凭证/芯片不得猜）。有外部缺项记录阻塞，继续不依赖部分；最终相关gate未过不得宣称全量交付。

实现工作台所需optional module和provider-owned边界，core scheduler/retry/reconciliation/workspace/credential posture整体继承。/保留runtime dashboard，/workbench为产品入口；原API兼容。新增数据不是第二份ticket状态，图形不是新的工程真值。

Git操作严格执行docs/GIT_WORKFLOW.md：标题type(scope): 描述，检查通过后自动commit；push前原make all与适用gate通过，仅推任务分支并维护PR；Merging授权后执行原land。M0接入提交信息hook/CI，不能把包内脚本存在宣称已安装。

每个切片先实现完整可用路径与具体TC，再扩展。所有操作保留received/confirmed/applied/unknown差异；常规handoff不需要用户逐条审核。遇到问题实时记录症状、假设、实验、失败尝试、选项取舍、证据与限制，便于人理解并积累经验。

自动执行已授权的读、实现、修复和必要验证，不因普通实现选择反复请求确认。只有真实外部阻塞或必须改变用户目标/core契约时说明原因和最小影响。完成必要可审阅成果后再提出需要用户决定的问题。

最终必须：原make all通过；新contract/OTP/PTY/browser测试通过；Archify source/deliver/browser/visual证据齐全；真实tracker+Codex+选定硬件E2E通过；四页+架构视觉验收；新环境安装启动、备份恢复演练；交付artifacts与实际报告。报告使用templates/release-report.md，所有结果绑定实际revision，不捏造任何PASS。
