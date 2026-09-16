# Git交付流程验收

这些门槛补充TC23/TC24，不替代原core或产品验收。status是后续目标仓库接入状态；本轮仅提交信息检查器自测和本地临时仓库范围检查实际运行。

| 编号 | 要验证的行为 | 证据与通过条件 | 当前目标仓库状态 |
|---|---|---|---|
| GC01 | 标题、普通commit范围、真实merge例外 | 7组检查器自测；有效中文/英文/破坏性格式通过，无scope/错type/空格/超长/假Merge/缺footer失败；实际hook与CI拒绝坏标题；PR标题同规则 | not_run：检查器已提供，hook/CI尚未接入 |
| GC02 | 提交前与push前gate | 本次staged tree对应测试证据；失败不提交/不push，用户改动未混入；make all及相关gate可按同tree证据复用 | not_run |
| GC03 | 自动commit与仅任务分支push | 一个可验证切片自动提交，一次任务完成后push；保护分支拒绝直推；远端并发拒绝后不force，缺凭证保留本地commit | not_run |
| GC04 | PR闭环 | 自动新建/复用Draft；base正确、模板与标题通过、真实Test Plan；证据齐全才Ready，反馈已处理 | not_run |
| GC05 | 原合并授权与land | 无授权不合并；人类Merging或已有有效授权后land；CI对应当前head，最终远端merged+SHA核对后Done | not_run |

演示/测试使用明确授权的测试repo；不为验收而破坏生产分支或制造真实有害合并。原workflow要求的技能缺失时如实blocked，不绕过。检查器只负责格式，Git操作的权限、测试结果和分支保护由实际宿主工作流/平台共同执行。
