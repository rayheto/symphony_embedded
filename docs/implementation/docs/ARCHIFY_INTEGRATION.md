# Archify skill 集成契约

## 固定来源与使用方式

本包检查 [tt-a1i/archify](https://github.com/tt-a1i/archify) 提交 `a07fa1d5b2a10cbea110c5a2be2817397a301cdc`，skill metadata 2.17。实施优先固定此 commit，若已有团队固定版本则先做capability diff，记录ADR后再更新pin。不修改或重新编写skill；安装方式遵守实际Agent环境和其SKILL.md。
读取顺序：已安装 `archify/SKILL.md` → architecture schema/common schema与一个相应example → 如需来源/交付/交互再读 references。不要把本包提示词当上游schema的替代品。

## 生成入口

`prompts/archify-project.md`、`archify-delta.md`、`archify-review.md` 为完整任务提示词。由当前Coding Agent或原有Issue任务触发；架构生成失败不会变更core retry策略。后台重生成按repo revision/计划revision去重，频繁日志不触发生成；source_changed只标stale。
本包不附冒充项目完成状态的架构HTML。当前提供的是实施规范，待Agent读取真实目标repo和revision后产出具体图。Symphony平台自身架构与被管理嵌入式产品用不同project_id。

## 产物与发布

每个 artifact_id 保存 `architecture.json`、`architecture.html`、`manifest.json`、`deliver.receipt.json`、`browser.receipt.json`、截图和 `visual-review.json`。manifest使用本产品独立schema，不向Archify IR增加layer_ids/issue_ids等未知字段。
manifest组件索引：id（对应IR id）、label、layers、source_refs、issue_ids、problem_case_ids、evidence_ids及独立实现/验证状态。relationships记录IR关系id/from_component_id/to_component_id/description/source_refs；没有关联时为空，不能增加IR不存在的边。
源码产物必有 source_revision；草稿/计划图把来源明确标为设计材料。Archify来源核验读取commit blobs，未提交工作区不在覆盖内；提示用户该范围，不声称HEAD图覆盖dirty tree。无需为了出图改用户工作树或自动提交。
只有CLI退出0且所有回执要求满足才能晋升last-good。原IR/HTML不可手工后处理；验收后任何字节改变都须重新deliver和browser QA。生成失败保留原last-good、显示尝试版本与诊断。

## 已核对CLI

以下在skill根目录执行，所有变量作为独立参数引用：
```sh
node bin/archify.mjs doctor
node bin/archify.mjs validate architecture "$candidate" --quality showcase --repo-root "$project_repo" --json
node bin/archify.mjs deliver architecture "$candidate" "$output_html" --quality showcase --repo-root "$project_repo" --json
node bin/archify.mjs visual-check "$output_html" --json
node bin/archify.mjs compare architecture "$base_json" "$head_json" "$delta_html" --receipt "$delta_receipt" --quality showcase --repo-root "$project_repo" --json
```
变量由任务上下文填写，不能把上述 `$candidate` 原样当文件名。首次候选后上游update-awareness按skill执行；不因此安装未固定版本。

showcase要求9项artifact checks，0 composition errors/warnings；4项basic不是showcase通过。deliver给规范/HTML sha256与bytes；visual-check有pass/fail/skipped真实状态（缺浏览器才允许skipped）。视觉审阅由读图或人类独立判断，自动检查不等于审美通过。
固定版本visual-check检查1440×900、1600×1000、1920×1080、2048×1320，并采集两端尺寸的light/dark截图。宿主iframe再额外测试实际区域尺寸；独立viewer通过不证明嵌入通过。

## 稳定集成与限制

宿主采用Soft Glass v1.0壳、工具栏与侧栏；图内保持Archify原生呈现，不向IR增加玻璃/字体字段或后处理HTML。用原生viewer的搜索/focus/export；没有经验证的postMessage API，不依赖伪造事件绑定。外围manifest列表提供组件→Issue/证据的穿透。默认`?theme=light`，这属于实际模板读取的URL参数，不是捏造IR meta.theme。
用sandbox iframe承载且不授予父应用同源访问；生成HTML不要innerHTML插入LiveView。新窗口打开也须以无应用cookie/凭证的隔离origin提供，或由用户下载到本地查看，不能撤掉iframe后在带写权限的应用origin裸跑。导出只允许用户手势；禁用外部任意脚本/链接按宿主策略核对，不破坏上游正常交互。
原生viewer的图内source links只支持固定版提供的provider；内部forge使用local-only且匹配origin。不能拼接猜测GitLab链接声称验证通过。
