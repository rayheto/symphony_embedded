# 分阶段实施与交付计划

每阶段交付可运行的纵向切片，完成必要gate后继续下一阶段；不把普通实现选择变成人工审批点。具体任务和owner/paths/deps见 `planning/tasks.json`。Owner是责任角色，不强制启用并发subagent。使用subagent时不分裂调度真值，符合现有Agent环境授权。

| 阶段 | 可运行成果 | 出口 |
|---|---|---|
| M0 基线与环境 | 原服务跑通、spec/schema检查、实际tracker/设备登记、依赖pin、保持原gates | baseline报告、provider状态/capability表、真实设备profile |
| M1 工作台任务闭环 | 顶部壳、真实Issues读/创建/详情、原runtime入口、Demo固定fixture、基础Store | UI/adapter tests，真实create可对账，无新scheduler |
| M2 调查与决定闭环 | Case/Evidence/Review/Operation、Agent上报工具、暂停/采用/计划引用/继续 | tracker+真实Agent确认新plan_loaded；unknown/conflict/restart测试 |
| M3 具体架构 | 固定Archify、source图/计划图/对比、last-good、manifest联动 | 源码pin/showcase/browser/视觉证据、真实项目图 |
| M4 设备闭环 | 串口helper/PTY/租约/图像/一个目标dump decoder/设备页 | 真实板录制、断连和占用测试、构建与证据闭环 |
| M5 完整发布验收 | Soft Glass四页美术+架构宿主页、透明度/动态降级与异常态、安装包、运维、完整E2E | R01–R12 trace闭环，make all，真实集成、视觉报告 |

M2提供执行中掌控方向，不能拖到最后。M4允许在开发期用PTY支撑开发，但M5禁止用PTY替代真实板验证。M0缺少设备时其它任务继续，相关真实gate标blocked，不能把首版缩水成无设备版本。

## 集成规则

每任务先读关联需求、契约和验收，列出改动路径与预期行为；局部单元与集成测试先行，完成后进可运行主线。公共 `mix.exs/mix.lock/router/config/dynamic_tool/supervisor` 由集成owner串行协调，不能多个Agent各自覆盖。现有root及elixir AGENTS更具体规则仍有效。
每个任务handoff记录代码revision、改动、测试结果、证据、影响、未完成项，可机器读取；用户默认只看工程问题与关键决定。任务计划变更不等于项目产品版本号；commit按连贯功能聚合，不在commit标题强塞M1/M2版本标记。
禁止只做UI再补数据；每切片必须经过生产边界读取/写入与failure反馈。新增mock只能测试边界，live mode不得静默读取fixture。

## Git交付流程

遵循GIT_WORKFLOW.md与GIT_ACCEPTANCE.md。T01–T02接入提交信息检查、原hook链和CI；T17–T18确认PR保护与合并gate实际有效。每个连贯切片在提交前检查通过后自动commit，任务/可审阅切片完成且push gates通过后自动push任务分支。Ready PR与人类合并授权分开；保留原Merging→land→Done流程。

## 变更处理

需求/核心语义/公共接口变更写ADR与最小diff，说明替代方案和影响并进入必要审阅；普通内部方法、CSS实现和局部命名由Agent自行完成。外部不可达不是永久删功能的理由，登记blocking evidence、继续不依赖工作。
每完成一个阶段更新阶段报告与traceability实际证据链接。此包TC是计划测试，所有产品结果初始not_run。
