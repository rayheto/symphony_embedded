# 原 SPEC 一致性与扩展对应

原文以逐字节快照保留。本包没有批准任何核心偏离。Appendix B 只在workbench启用时适用。实现若认为需要修改核心语义，应先记录具体条款、证据和替代方案，不能用本包的新名词解释成已授权重写。

| 原文条款 | 接受的核心理念/行为 | 扩展方式 | 验收 |
|---|---|---|---|
| §1–2 | 长期运行服务、Issue驱动、自主执行、工作流在仓库 | 工作台服务于理解和输入方向 | TC01,TC02 |
| §3–4 | 分层组件/稳定ID；runtime facts有单一owner | 工程实体关联原Issue/Run，不取代它们 | TC01,TC04 |
| §5–6 | WORKFLOW发现、严格模板/类型、reload与last-good | 通过原Config管道添加workbench/profile字段 | TC02 |
| §7 | 原claim/run生命周期和幂等恢复 | Operation/Review只属于工程应用状态 | TC01,TC07 |
| §8 | 轮询、候选、并发、retry/backoff、reconciliation | pause用原生非active状态，仍由原reconciliation停worker | TC07,TC08 |
| §9 | workspace复用、hook、containment及终态清理 | 证据独立data_root，清理语义保持 | TC05,TC16 |
| §10 | 原app-server协议、timeout、approval/tool/user input政策 | 增加结构化工程工具，回执绑定当前run | TC06,TC08,TC09 |
| §11.1–11.4 | tracker adapter原读契约与错误映射 | 完整Issues展示读取独立display states | TC03 |
| §11.5 | 工单写入/业务流属provider tools与工作流 | UI通过provider-owned WorkbenchAdapter，不往core CRUD下沉 | TC03,TC07 |
| §12 | prompt严格渲染、重试与continuation上下文 | workpad包含versioned plan ref与domain政策 | TC06,TC08 |
| §13 | 日志、snapshot、可选HTTP、humanized摘要非权威 | 保留原dashboard/API；新增工程观察与原始证据下钻 | TC01,TC04,TC18 |
| §14 | 失败隔离；重启重新读取tracker构建运行 | Store重建只恢复工程历史/对账，不恢复另一调度真值 | TC08,TC16 |
| §15 | 受信任环境、路径/secret/hook安全 | 继承session/CSRF、HTML隔离、设备动作allowlist | TC15 |
| §16 | 参考启动/派发/退出算法 | 无替代算法；最小观察hook独立于关键路径 | TC01,TC16 |
| §17–18 | 原测试矩阵与完成条件 | 原gates全部保留，增加R01–R12证据 | TC01,TC24 |
| Appendix A | SSH worker扩展原有语义 | 设备host身份显式、artifact通过受控回传绑定 | TC12,TC15 |

## 具体实现新增与原有能力

现有 `/` 是runtime dashboard，四页美术中的Issue看板不是当前代码现成页面。新增 `/workbench` 不删除 `/`；原 `/api/v1/state`、`/api/v1/refresh`、`/api/v1/:issue_identifier` 保持兼容。
首个UI provider是Linear，选择来自已有实现与原workpad策略；其它原有provider core仍保留。这是首版扩展支持范围，不是把原产品缩成仅Linear。
结构化工程事件是原日志/摘要的补充；普通handoff继续自动流转。证据写失败需要报告给当前工程工作流，但不能改变Orchestrator的通用重试含义。
Archify是产物生成工具，仍由原Issue/Agent工作流执行架构任务。DeviceManager管理物理资源，不控制Agent并发。工程Store保存耐久证据，不保存dispatch lease。
