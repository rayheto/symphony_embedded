# Archify：发布前独立审阅

输入实际IR、HTML、manifest、receipt和指定repo revision。不得仅阅读Agent自述。
1. 核对origin、commit、引用路径/行、组件和关系；图是否对应具体项目而非模板？未知/计划是否标识？
2. 校验manifest组件/边存在于IR，source evidence覆盖范围真实，来源哈希与当前HTML一致。
3. showcase是否9/9、0error/0warning？deliver exit是否0？browser结果是否完整？skipped必须有实际环境原因。
4. 打开实际截图/HTML检查字体可读、节点不遮挡、标签不压线、各视口无隐藏裁切；独立审阅不能让机器receipt代替。
5. 查看默认light与宿主嵌入状态，iframe隔离、独立打开、原始导出和来源入口是否可用。
6. 确认架构变化不被渲染成“测试通过”；图不暴露凭证，runtime状态不会被动画暗示。
输出通过/失败及逐项证据，分别填写validation、browser_evidence、visual_review；明确原始文件路径与sha256。失败说明具体修复，不使用笼统“看起来不错”。
