# 当前视觉基线：Symphony Soft Glass v1.0

用户于2026-09-15选定本风格，替换上一版实施包的视觉指引。完整新交付包原样展开在 `soft-glass/`，包含四张单页预览、风格指南、精确SVG色板、参考图、tokens/CSS及实际出图/纠错提示词。

阅读顺序：
1. [实施视觉规格](../docs/VISUAL_SPEC.md)与[本次更新记录](../docs/DESIGN_UPDATE_SOFT_GLASS.md)。
2. [新交付README](soft-glass/README.md)、[风格指南](soft-glass/design/Symphony-Soft-Glass-guide.md)。
3. [业务字段原文](soft-glass/design/Symphony-design-prompt.md)和[四页预览目录](soft-glass/previews)。
4. [tokens](tokens.json)与[CSS](tokens.css)。它们是新包对应文件的逐字节副本，不继续使用旧变量/结构。

权威分工：业务字段、日志、状态与动作遵循业务字段原文及产品契约；视觉参数遵循Soft Glass指南+tokens+CSS。业务原文中的旧14px正文、22px标题、小圆角及深灰主按钮已被新版替代；它仍随新包原样保留以保证业务数据可溯源，不能再拿旧视觉值覆盖新风格。指南里的“可选视觉迭代”描述的是来源文件形成时状态，用户本次已明确选用。

`reference/design-prompt.md`仅是业务字段原文的兼容路径，字节与新包一致。旧总览PNG和旧出图提示词已从当前实施包移除，避免Agent混用；上一版交付可通过版本历史查阅。新包PNG不是浏览器运行截图，不从PNG取色/OCR/增加头像、评论数或日期。
