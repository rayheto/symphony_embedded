# 实施包验证报告 — Git规则更新

日期：2026-09-15。保留Soft Glass视觉基线，补齐commit/push/PR/合并规则。本报告区分实施包检查与目标产品/远端流程验收。

封包前14类检查通过、0失败；封包后另检查清单存在与全部文件哈希。

| 检查 | 结果 | 实际内容 |
|---|---|---|
| inventory | passed | 62 required entrypoints exist |
| baseline | passed | Original SPEC and all current Soft Glass source files preserved; combined SPEC synchronized |
| syntax | passed | 28 JSON and 4 YAML files parsed |
| schemas | passed | 4 JSON Schema Draft 2020-12 documents valid |
| fixtures | passed | 35 entity/helper examples and workbench configuration valid |
| openapi | passed | OpenAPI 3.1 valid; 34 shared definitions identical |
| agent_tools | passed | 7 agent tool input schemas valid |
| negative_fixtures | passed | 8 malformed/ambiguous fixtures rejected (schema only, not service tests) |
| fixture_relationships | passed | 8 cards, draft adoption, distinct unconfirmed build sessions and raw log hashes correct |
| traceability | passed | 12 requirements, 18 acyclic tasks, 24 planned acceptance scenarios |
| local_links | passed | 31 local Markdown links resolve |
| visual_tokens | passed | Soft Glass source copies, full color mapping, 15/28px typography, 10/16/20px radii and fallback declarations verified; browser behavior not tested |
| design_source_manifest | passed | 17 vendor-manifest assets verified; obsolete preview/prompt removed |
| git_policy | passed | Conventional Commit project policy and 7 validator self-test groups passed; target hook/CI/remote operations not exercised |

## 本轮检查器实测

提交信息检查器7组自测通过，覆盖中文/英文、scope/type/长度/空格、正文分隔、破坏性双标记、PR标题与CRLF。另在一次性本地Git仓库实测4个断言：新增普通commit通过且排除旧base历史；真实merge按父节点豁免；伪造Merge标题的普通commit拒绝；不存在的提交范围拒绝。记录见verification/commit-range-validation.json。hook样例通过sh -n语法检查。

## 沿用的设计来源验证

Soft Glass原包17个manifest列出资产及manifest自身原样保存，tokens/CSS副本校验一致；前轮已逐张查看4页PNG并核对源图片尺寸，本轮未重新生成图像。源SPEC、接口及工程语义没有因Git规则更新而改写。

## 仍未执行

目标仓库hook/CI接入、分支保护、真实push/PR/land均未执行；工具存在不等于远端已强制。原make all、工作台浏览器/设备/真实Agent测试、实际Archify出图仍为实施阶段验收。GC01–GC05的目标仓库状态保持not_run。

## 复核

```sh
python3 -m pip install -r requirements-validation.txt
python3 scripts/verify_pack.py --require-manifest
python3 scripts/check_commit_message.py --self-test
```

修改本实施包后按需运行scripts/sync_spec.py，再运行scripts/refresh_manifest.py和verify_pack.py --require-manifest。哈希清单不能代替产品测试。
