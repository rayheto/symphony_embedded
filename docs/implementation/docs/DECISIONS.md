# 架构决策记录

这些是本次实施方案的明确默认选择；不代表已经实现。变更须更新本文件并给证据。

| ADR | 决定 | 原因 / 不采用的方向 |
|---|---|---|
| ADR-01 | 原SPEC原文保持，Appendix B可选扩展 | 尊重完整理念；不新造scheduler/workflow engine |
| ADR-02 | 沿用Elixir/Phoenix/LiveView | 实际仓库已有；不引入独立React全栈与双状态权威 |
| ADR-03 | Linear作为首个完整工作台provider | 原工作流和示例已有；其它adapter core继续支持但UI capability实报 |
| ADR-04 | 文件CAS+单writer工程journal | 审阅材料需要持久化，调度无需数据库；未来存储实现可替换 |
| ADR-05 | Archify skill拥有图形层 | 用户明确要求；不写自有renderer或改变已检验HTML |
| ADR-06 | 原生viewer+manifest外围联动 | 固定版未提供本产品需要的host event API；不依赖DOM内部协议 |
| ADR-07 | 2026-09-15用户选定Soft Glass v1.0替代上一视觉基线 | 顶部双行导航、系统无衬线、15px正文、分级圆角、克制蓝色主动作、仅导航轻磨砂；业务字段不变 |
| ADR-08 | 单宿主设备适配和Python Port helper | 串口生态明确、二进制与Elixir业务隔离；原core与hardware分离 |
| ADR-09 | 暂停通过native非active状态 | 继续沿用reconciliation/restart；不以kill/closed代替暂停 |
| ADR-10 | 芯片/端口/凭证在M0登记 | 用户未指定首版目标，示例不是硬件事实；相关gate必须真实完成 |

ADR变更格式：问题→现有约束→候选→选择理由→影响需求/契约/测试→迁移与回退→是否需用户决定。技术探索无论失败或成功都保留证据，避免后续Agent重复已证伪路线。

ADR-11（2026-09-15）：提交标题采用Conventional Commits项目约束（强制scope/72字符/破坏性双标记）；检查通过自动commit与任务分支push，维护Draft/Ready PR；继承人类Merging授权及land流程。来源与详细门槛见GIT_WORKFLOW.md。
