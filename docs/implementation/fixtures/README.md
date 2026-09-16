# 演示与契约样例

八张卡、两组日志、A/B候选与限制均按新Soft Glass包内业务字段文档逐项录入（该文档与上版业务字段字节一致）；视觉参数改由Soft Glass guide/tokens/CSS负责。冻结clock_utc便于截图；相对时间显示使用display字段，不能在真实模式硬编码。所有provider/设备/执行回执是fixture，不是已经发生的工程事实。真实模式禁止加载本目录作为fallback。

同一个boot显示名并不证明两份材料来自同一会话。附件E-017写demo-build，设备页写demo-build-12；保留两者原文，用不同capture session建模并标关联未知，禁止自动拼接或推导根因。设计中待审阅EMB-40的暂停回执作为独立演示状态，列名来自展示映射，runtime三运行/一暂停不由卡片数推断。

`entities/`用于Schema正向测试，不表示数据库初始种子都应直接导入。尤其ArchitectureArtifact仅空态；真实架构在目标源码确定后通过Archify生成。`raw/`精确可复制，所有hash根据本包原始bytes计算。

Demo的意见/采用等动作若用于交互演示，仅写隔离demo Store并有显著标记；不能写真实tracker、连接真实设备或上报为live验收。
