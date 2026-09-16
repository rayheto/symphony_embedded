# Archify：具体项目架构生成任务

使用已安装、与sources.lock匹配的Archify skill。先读其SKILL.md，严格按当前schema、artifact-first、有限修复和交付约束执行。本任务不允许以其它renderer或ImageGen代替。

## 输入（由调用工作流填写，缺失不得猜）
- project_id / 项目名称。
- repository_root / credential-free origin / 完整40字符revision。
- generation_kind：source_baseline、source_in_progress、planned三选一。前两者映射manifest kind=source，第三者kind=plan；building/integrated来自组件工程状态，不新增IR枚举。
- 该revision对应的入口、配置、构建、部署与设备资料范围。
- domain_profile路径，关联Issue/Problem/Evidence索引；没有关联则空。
- planned图的明确设计文档与plan_revision；source图不得拿计划冒充实现。
- output_directory（在宿主配置允许的架构产物目录，不随workspace删除）。

## 内容

从具体项目入口追踪真实组件与关系。先确认项目是Symphony平台本身还是被管理的嵌入式产品，禁止混图。输出8–12个主要组件的总览，复杂部分分图；稳定节点/边ID。读取路径和引用必须对应指定commit，保留函数/模块/协议实际名字。必要时用layer标签说明L0–L4，不以层名替代组件。
硬件事实只从原理图/datasheet/板文件/实测来源获取；未知就标unknown。OS调用可绕过驱动层，设备路径走受控接口；Feedback横跨层级。区分调用、数据、配置与硬件关联，不因几何邻近产生关系。
每个source节点附1–3个真实components[].sources；边的依据放外围manifest关系索引。没有足够来源不发布为verified source。dirty工作树未包含于commit，明确展示限制；不要为出图擅自提交用户分支。

## 呈现

中文说明，原代码/协议名保留；`meta.locale: zh-CN`、`meta.quality_profile: showcase`，省略visual_preset使用classic，默认静态；仅用户明确要求时启用动画。宿主UI为Soft Glass v1.0，但图形内部保持Archify合法schema/原生classic，不要求通过任意HTML/CSS修改模拟玻璃。浅色通过viewer实际支持的theme=light方式；不编造meta.font等字段。短标签，留白，少量有意义连接；不是把所有信息塞一页。

## 校验与交付

使用上游architecture/common schema和一个example后立即写候选。按skill validate；来源图使用--repo-root。严格区分9项showcase和4项basic。成功deliver后再visual-check，读取真实截图审阅。不能手改HTML后沿用旧hash。
失败按diagnostics的subject/evidence/supportedFixes有限修复，超过skill限额保留last-good并报告，不把失败候选标完成。
返回：IR、HTML、manifest、spec/artifact SHA256、deliver receipt、browser receipt、visual review和limitations。manifest遵循本包architecture-manifest.schema.json，绝不向Archify IR塞不支持字段。
