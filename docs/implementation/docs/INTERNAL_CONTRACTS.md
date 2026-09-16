# 内部模块契约与集成挂点

本文件固定语义，不要求逐字照搬模块名。Elixir公开函数遵守既有@spec规则；错误返回 `{:error, code, details}`，不得吞掉故障并返回空成功。下列函数均为待实现，不冒充上游现有API。

| Owner | 最小接口 | 一致性/失败约束 |
|---|---|---|
| Store | append(project, type, id, expected_revision, attrs, actor, key); get_revision; list; replay(after_seq); put_blob(stream); get_blob | 单writer，先durable后ack，CAS/幂等，原件不可改，越权拒绝 |
| Query | snapshot(project); list_issues(filters,cursor); get_case; list_reviews; device_sessions | 聚合权威来源，返回来源时间与健康，禁止调度副作用 |
| WorkbenchAdapter | capabilities; metadata; list_issues(display_states,cursor); get_issue; create_issue; transition; find_operation_marker; get_workpad; update_workpad_plan; comment | provider-owned；复用原client；写结果unknown必须可对账；不能承诺provider不存在的CAS |
| Operations | submit(actor, typed_request); get(id); reconcile(id) | 保存意图/回执，不形成另一scheduler；重启只恢复对账 |
| AgentTools | specs(bound_context); execute(name,args,bound_context) | 原session绑定provider/project/issue/run；不能冒充human、越过workspace或改core状态 |
| Architecture | request(project,source); validate_and_publish(manifest); list_revisions; viewer_descriptor | 请求映射到原Issue工作流，生成由Archify；无新Agent执行循环 |
| DeviceManager | register; probe; open_capture; close_capture; acquire/renew/release_lease; run_action; query_action | 控制独占/读共享；代次持久；未知动作先观测；原bytes和gap可溯源 |
| SerialPort | start(parsed_device_config); request(frame); handle_frame; stop_capture | 仅JSONL协议；stdout非日志；raw→chunk，不阻塞Orchestrator |

## 最小上游改动范围

配置：扩展原Config/Workflow typed pipeline与校验，不新增配置加载竞争者。启动：HTTP存在且workbench启用时在现有Application supervisor下启动独立Experience subtree。关闭工作台时不启动采集/图任务/相关资源；原runtime工作照旧。
观察：优先现有ObservabilityPubSub及Orchestrator snapshot。需要精确worker停止信息时加小型只读结构化观察，不能从UI按钮或provider状态推断已终止。
工具：在原DynamicTool构建处组合provider工具与engineering tools，保持既有unsupported handling/session配置绑定。raw stdout、serial帧、HTML不得作为大消息进入Orchestrator。
路由：保留原scope；/workbench为LiveView，/experience/v1为同域受控API；API/LiveView都调用同一Operations/Query。前端局部缓存不写业务真值。
状态映射：provider metadata将原native状态映射展示列；paused不是新的core claim state。Agent自报状态只有observed/reported意义。

## 工程状态的事件来源

Case/Claim/Experiment来自显式工程report。Validation来自带环境与criterion的测试执行记录。Review来自具体actor行为。Decision采用来自用户动作。运行态来自原runtime。设备态来自helper/adapter。图节点状态是上述记录的投影，不能让图生成Agent凭印象设置绿色passed。
Evidence.review_status与Case.state.human_review_status是Review事件投影；原始Evidence内容、binding和bytes保持不可变。投影revision随review事件增长，不重写已归档原件；读取具体旧revision仍可还原当时状态。

## Schema版本与迁移

本包契约schema_version为1.0。首版存储记录envelope包含schema_version、project_seq、entity_type/id/revision、payload、payload_sha256与recorded_at；每行checksum针对canonical JSON payload（UTF-8、sorted keys、无额外空格），记录长度/完整换行判定尾部写入。中段校验错误必须只读故障，不能当尾部截断。
升级先备份；只迁移工程数据，不篡改blob或历史Evidence含义。未知未来版本拒绝写入并显示需升级；不降级猜读。开放新枚举/API字段需要同步schema、fixtures、服务/客户端和TC。为保持首版简洁，只有真实需要的版本迁移才实现，禁止预造通用迁移平台。
