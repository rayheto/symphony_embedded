# UI控件与行为映射

与交互规格一起实施，消除“画了按钮但没有真实路径”的交付。REST是共享领域接口的公开契约；LiveView可直接调用同一服务，不要求内部HTTP往返。所有写通过Operation；Demo仅写隔离演示状态。控件外观遵循Soft Glass：每操作区域至多一个蓝色主动作，其余次级样式；设备页签用灰色分段控件，补证据必须是真按钮，保留账号入口。表中“外链”使用已知来源URL，不拼猜链接。

| 页面/控件 | 行为或服务入口 | 失败/验证 |
|---|---|---|
| 顶部Symphony / Embedded Lab | 菜单显示当前项目、配置与可用项目；首版单project可解释不可切换 | 不伪造未支持多租户 |
| 链接/更多/头像 | 项目源码链接、原runtime `/`、工作台配置/版本信息、当前可信身份 | 无来源禁用说明；不暴露token |
| Issues / 筛选 | GET issues(q/state/assignee)，URL query保存 | 空结果与网络失败分开 |
| 显示 | 列表/看板和可见状态；本地偏好，不改tracker状态 | 刷新/后退恢复 |
| 新建/列底添加/列头+ | 先provider-metadata，create_issue；列入口预填合法状态 | 缺权限或stale元数据不可提交 |
| 卡片/打开Issue | 内部详情/已知provider URL | 未找到对象明确404 |
| 卡片/列头更多 | 卡片提供打开原工单、更改合法状态；列头筛选该状态 | 不默许拖拽状态、关闭代暂停 |
| 页签概览/活动/调查/变更 | IssueContext、事件、Case/Evidence、ChangesView | 各块独立loading/error；保留原始活动可下钻 |
| 证据tab/展开上下文/原始记录 | Evidence/原件授权下载；原chunk字节范围定位 | raw缺失/hash错误不替换同名文件 |
| 意见发送 | comment，默认只是意见 | 输入保留、幂等/CAS、无暗中恢复 |
| 调整约束/铅笔 | adjust_constraints，区分草稿编辑与已采用修订更新 | 明确实际执行后果和新revision |
| 要求补充证据 | request_evidence；非active时单独显示继续执行入口 | 请求记录不等于Agent已接收 |
| 查看关联架构 | architecture路由带component/issue query | 无图可生成，不展示假关联 |
| A/B选择 | 客户端候选，联动比较/按钮文案 | 不生成adoption |
| 采用方案 | adopt_decision；展示是否暂停和是否恢复 | 状态从Operation回执更新，202不等于完成 |
| 暂停/恢复/处理未知结果 | pause_issue/resume_issue/reconcile_operation | provider确认、runtime停止、unknown分开 |
| 审阅记录 | decisions/reviews列表及绑定revision详情；review动作 | 查看不等于接受，意见不可覆盖历史 |
| 设备刷新 | devices?refresh=true，只读probe/健康检查 | 失败显示旧状态时间，禁止保持假在线 |
| 添加设备 | 从宿主已配置设备选择，probe后register_device | 未配置引导配置文件登记，不接受任意shell |
| 串口连接/断开 | connect_device/disconnect_device管理采集 | 停止采集不宣称停止物理动作 |
| 暂停滚动 | 仅固定前端viewport+未读计数 | 原始采集与写盘继续 |
| 导出/完整记录 | sessions/{id}/export 与 serial游标 | 原始bytes+元信息；导出限流/取消不影响采集 |
| 连接图像源 | observations列合法源→set_image_source→连通检查 | 未连接/error明确；source_key=null断开观测源 |
| 保存帧/上传图像 | capture_image 或 blobs + register_evidence | captured_at未知保留null，原件hash绑定 |
| 故障记录/查看历史 | observations.fault_evidence_ids→Evidence | 仅本次无记录不推断系统无故障 |
| 解码dump | decode_dump（选择匹配已登记ELF） | unknown/mismatch禁确定调用栈 |
| 查看构建记录 | build-records drawer | build标签相同不证明匹配 |
| 设备操作 | allowlist capability→acquire lease→run_device_action→真实终态 | 过期租约/未知副作用拒绝重放 |
| 架构视图/版本/更新 | architecture列表、source/plan筛选、generate_architecture | 对应实际来源；生成失败显示last-good/stale |
| 架构对比 | 原工作流生成Archify compare source base/head产物 | 禁把结构diff当验证结果 |
| 架构组件索引 | manifest索引→组件来源/Issue/Evidence侧栏 | 不依赖未声明的iframe点击协议 |
| 独立打开/下载 | 隔离origin或授权下载 | 禁给HTML宿主cookie权限 |

每个菜单只显示实际支持且有明确去向的操作；未实现的“更多”不能留空占位。设置首版是当前配置/路径状态说明与reload结果，不另建未经定义的多用户设置平台。
