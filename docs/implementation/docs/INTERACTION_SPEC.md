# 交互与行为规格

## 导航与路由

两行顶部壳：Symphony / workspace + 链接/更多/头像；第二行 Issues、项目架构、设备、审阅记录。工作区切换与设置放菜单，所有入口键盘可达。无左侧大导航。
`/workbench` 重定向 `/workbench/issues`。其它 routes：`/workbench/issues/:identifier`（tab 参数 overview/activity/investigation/changes）、`/workbench/architecture`、`/workbench/devices`、`/workbench/reviews`、`/workbench/reviews/:decision_id`。`/` 原 runtime dashboard 保留；“查看运行状态”进入 `/`。
列表筛选/展示模式/选中设备或图快照写 URL query，浏览器刷新和后退恢复；临时未提交评论提示离开，不把 draft 偷偷发布。

视觉遵循Soft Glass v1.0（docs/VISUAL_SPEC.md）；不从旧业务原文恢复已被替代的字号/圆角/主按钮颜色。生成PNG漏掉的账号入口、补证据按钮仍须实现；设备tab统一浅灰分段控件。

## 所有页面通用状态

loading 显示结构骨架；empty 解释下一步且不伪造示例；error 保留已成功读取区块并显示原因/重试；stale 标读取时间，关键变更操作需 refresh/CAS；unsupported 解释缺失 capability；permission_denied 不出现可执行按钮。Demo 横幅持续可见且不接真实设备/原生 mutation。
表单提交有 submitting；失败保留输入；409 显示旧/新目标，要求重新检查后再提交；同幂等请求不可双写。读界面暂停滚动不暂停设备。草稿选择与 adopted 用不同文案。

## Issues

默认看板，四列由 display mapping 获取；最新附件八卡作为固定 screenshot fixture。真实项目额外状态不能漏，放显式“其它状态”列或显示菜单；不能当 Todo 猜。列表/看板共用 filter和data source，状态统计注明筛选范围；runtime 数来自原 snapshot，不以 In Progress 卡数替代。
新建入口打开表单（标题必填、描述、原生状态、负责人、标签）；加载 capability/选项后可提交；应用不允许任意越权项目。成功后从 provider confirmed 数据插入并可打开 Issue。卡片列头/底部添加预填该列合法状态。
首版不启用拖拽变更状态；用卡片更多“更改状态”选择真实合法目标并按 provider confirmation更新，不能假乐观移动后丢错误。筛选按标题/identifier/assignee/state；显示菜单保存模式。

## Issue 与调查

完整元数据与打开原生 Issue；概览显示描述与计划引用，活动显示原始 Agent 事件与 handoff（默认折叠），调查页按 Case 展示；一个 Issue 多 Case 时有选择列表。
当前判断始终带假设/已证实/证据不足状态，点击实验打开关联原始材料。时间线用真实 occurred_at，latest step 按事件顺序一致。失败尝试不得自动隐藏。
证据侧栏约40%，可关闭；日志/图像/信息 tab 只在存在或可说明空态时显示，原始记录可复制/下载，行上下文可展开；绑定条件、limitations与human review持续可见。来源损坏显示missing，不换成另一个同名文件。
变更页绑定明确base/head/未提交patch，显示可复制diff与来源，无法读取时说明原因。设备构建记录采用详情抽屉，不增加顶层导航。
评论与约束从同一个输入区进入：默认“评论”，选择“调整约束”后展示影响与暂停/更新计划语义，避免一句随意评论自动变成控制指令。

## 方案审阅

审阅记录页列待决定与历史，具体页两栏 64/36。A/B 单选只改候选；采用按钮文案随选择变化（不能选 B 仍写采用 A）。对比内容也随候选，所有证据引用绑定同一 revision。
采用前明确显示：会记录决定、更新指定 Issue 计划、是否暂停、是否随后恢复；提供选择不强制全局 modal。必须保留 adopted、workflow applied、plan_loaded、verified 的不同状态。未回答不自动同意。
右栏影响为有依据的已知范围，未知依赖注明；执行回执按真实结果显示 pending/confirmed/failed/unknown。缺证据仍可选探索性方案，但不能自动给 PASS。

## 设备

设备表格选中恢复到 URL。添加设备选择宿主已配置设备标识（列出 adapter、端口与串口参数），填写 display_name，连接探测后登记；未配置设备引导按运行手册登记并reload，不自动认领未知 USB。设备详情：概览/串口/图像/故障记录。
串口实时缓冲5000行，暂停滚动固定当前 viewport并显示未读行数，采集不停止；恢复滚动回到底部。导出选择会话/区间，默认原始材料加元信息。断连标时间与gap；重连重新确认端口身份和boot。端口占用显示 owner与只读订阅说明。
图像连接打开已配置合法源选择/上传，源不存在时空态；一帧绑定 captured_at/received_at/session并可保存为证据。故障记录包含raw dump下载、构建匹配与decoder结果；不匹配时禁用确定解码显示，历史仍可读。
设备操作菜单只列支持动作，正在占用时拒绝冲突操作；动作反馈明确 physical outcome，与暂停 Issue 状态分开。

## 项目架构（第五页）

沿用顶部壳，主区为具体项目 Archify viewer。工具栏：已集成/正在构建/计划目标、revision选择、生成/更新、对比、独立打开。按 L0–L4 的导航是manifest筛选/相关图选择，不把真实拓扑替换为五层模板。
无图：说明未生成，允许为明确 repo revision 创建架构任务；生成中继续展示带版本的 last-good；失败展示诊断与重试入口；旧图标stale。不同图来源/修订不能被缓存串用。
viewer内搜索/缩放/focus使用 Archify 原生能力；外围提供组件索引，选中后侧栏显示 sources、Issue、Case、验证。首版不承诺图节点自动触发宿主侧栏，因 Archify未声明该跨页协议。用户可通过组件索引完成相同穿透任务。
对比区使用 Archify compare 产物，说明只有结构变化，不等同运行影响/安全结论。未经验证图显示 draft，禁止用“已完成”标签混淆。

## 键盘与辅助访问

Tab 顺序按导航→工具栏→主区→侧栏；关闭抽屉返回触发控件；Escape关闭非破坏性弹层。按钮有accessible name，文本可选，状态有形状+文字。日志使用可访问预格式文本/虚拟列表且保留原始下载；不会频繁抢focus。相对时间悬停显示UTC及本地时区。
