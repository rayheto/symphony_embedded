# 验收规格与证据门槛

本包定义待实施测试；以下所有产品测试初始 `not_run`。实施包自检的通过不改变这些状态。每个测试记录环境、代码revision、命令、开始/结束UTC、退出码、artifact hash及适用范围。失败/blocked/skipped均有原因；未运行不使用passed。

## Gate层次

G0：实施包结构/Schema/追踪自检。G1：原core `make all` 与增量领域/adapter测试。G2：Demo/PTY/浏览器集成。G3：真实tracker+Codex+实际目标设备。G4：美术、理解、安装和恢复验收。完整发布需要G1–G4；没有真机不能拿G2替代G3。

## 场景

### TC01 原核心一致性

关联：R01。状态：not_run。

操作与环境：禁用workbench启动原服务；运行原core套件；观察原三个API。

通过条件：原行为和字段兼容；没有新增调度owner；启用后UI故障不改变core。

失败/反向检查：截断UI进程/无HTTP端口不能停止正常后台任务。

提交证据：原make all输出、baseline与修改后API结构对比、supervision故障记录。

### TC02 配置与reload

关联：R01 R09 R11。状态：not_run。

操作与环境：加载有效profile，reload显示状态；再加载无效YAML/越界data_root。

通过条件：合法展示立即更新；敏感资源明确重启；无效配置保留last-good。

失败/反向检查：数据根在workspace内/模板未知变量必须报错；不得静默demo。

提交证据：配置输入、日志、前后snapshot、负向断言。

### TC03 真实Issue闭环

关联：R02。状态：not_run。

操作与环境：在授权Linear测试项目读取全展示状态、筛选、创建、变更合法状态并打开原生链接。

通过条件：Todo/Review/Done不因不在running中消失；provider读回后更新UI。

失败/反向检查：创建返回超时后同key不重发；其它provider不支持暂停显示unavailable。

提交证据：provider ID/marker、读回结果、UI录像、调用次数断言。

### TC04 调查与失败尝试

关联：R03 R04。状态：not_run。

操作与环境：Agent依次上报假设、反证实验、当前判断和下一步；UI下钻。

通过条件：被否定假设保留；最新节点顺序正确；两次导航内打开原始材料。

失败/反向检查：没有证据不能显示root cause confirmed；错project引用拒绝。

提交证据：实体修订、事件cursor、截图、原件hash。

### TC05 不可变证据与适用范围

关联：R04 R11。状态：not_run。

操作与环境：保存bytes→Evidence→Validation；更换build/config后查看当前与历史。

通过条件：历史结论可查；新scope显示stale或不适用；原始字节完全一致。

失败/反向检查：哈希损坏、缺blob、超range、未知build均不得作为当前PASS。

提交证据：blob/hash、binding对照、旧新revision、错误返回。

### TC06 Agent工具与单workpad

关联：R03 R05。状态：not_run。

操作与环境：真实run读取计划并上报Case/Evidence；重复上报相同幂等key。

通过条件：同事件不重复；单workpad可读计划和证据；actor绑定run。

失败/反向检查：伪造human accepted、越界文件、跨Issue写拒绝；报告不能清除人工review。

提交证据：实际tool调用/返回、workpad前后、run_id、拒绝用例。

### TC07 暂停与恢复

关联：R05 R11。状态：not_run。

操作与环境：正在running Issue请求暂停；provider确认；等原reconciliation停worker；重启再观察；显式恢复。

通过条件：provider非active非terminal持久；无worker后显示已停止；重启不重派paused。

失败/反向检查：provider写超时不能显示已停；禁止用closed暂停；连续点击无双写。

提交证据：provider日志、runtime快照、Operation各阶段、重启录像。

### TC08 采用方案完整回执

关联：R05 R11。状态：not_run。

操作与环境：运行中采用A；暂停确认；发布计划引用；显式恢复；下一真实Agent上报plan_loaded。

通过条件：adopted→workflow applied→plan_loaded→验证分别可见；旧turn不在新引用发布后继续执行旧计划。

失败/反向检查：断网/崩溃在每个副作用边界注入，恢复先对账；旧revision409；未点击采用无写入。

提交证据：Decision/hash、provider读回、停止与新run时间、tool回执、故障注入报告。

### TC09 补证据与人的方向

关联：R05。状态：not_run。

操作与环境：对非active Issue请求证据、评论、修改约束；检查任务行为与显式继续。

通过条件：评论不控制；补证据先存请求；约束创建新plan并影响下一有效run；默认handoff不审批。

失败/反向检查：仅选B不能改变决定；选B按钮/对比不能仍呈现A；未回答不自动同意。

提交证据：交互测试、workpad、新旧plan与run关联。

### TC10 具体Archify源码图

关联：R06。状态：not_run。

操作与环境：对实际目标repo完整revision用所附prompt生成IR，validate/deliver/visual-check。

通过条件：showcase 9 checks/0 error/0 warning；source路径行号可定位；hash绑定HTML；具体模块可读。

失败/反向检查：用固定五层模板、dirty HEAD冒充当前、来源不匹配、仅4 checks必须失败或标draft。

提交证据：原IR/HTML/manifest、deliver回执、浏览器截图、独立视觉审阅。

### TC11 架构比较与失败恢复

关联：R06。状态：not_run。

操作与环境：实际两个源码revision生成compare；另生成有来源的计划图；模拟新版本生成失败。

通过条件：source/plan/delta区分；比较回执可查；last-good保留且stale可见。

失败/反向检查：结构diff不能声称运行验证；失败不能把旧图当新成功；图节点无来源不能假填。

提交证据：两个commit、compare JSON/HTML、失败诊断、UI状态截图。

### TC12 串口PTY可靠性

关联：R07 R11。状态：not_run。

操作与环境：PTY发送无效UTF8/64KiB以内二进制/突发流/断连；暂停滚动再恢复。

通过条件：原始bytes/hash一致；seq有序；显示buffer≤5000；pause只影响滚动。

失败/反向检查：Port退出必须显示gap或断连，不能丢帧而仍声称完整；不能喂活Agent stall。

提交证据：PTY脚本、发送与接收hash、session/gap、内存/延迟记录。

### TC13 真实板设备链

关联：R07 R12。状态：not_run。

操作与环境：选定真实板登记、采集、确认firmware绑定、保存证据、拔插重连并导出。

通过条件：连接与验证分离；新session/boot按实测；导出原件可独立复查。

失败/反向检查：USB端口复用接入另一板必须重新验证；未知boot不得猜；PTY不替代真板。

提交证据：设备照片/标识、build材料、真实串口文件、导出ZIP、现场执行记录。

### TC14 图像与dump

关联：R08。状态：not_run。

操作与环境：真实图像源或上传帧绑定时间/session；实际目标产生dump，用匹配ELF解码。

通过条件：原件、工具/参数/退出值保存；至少一个实际decoder真机验证；图像假设标derived。

失败/反向检查：换错误ELF/未知build/decoder crash不显示确定调用栈或success；空故障页不表示无故障。

提交证据：帧hash、raw dump、ELF/hash、匹配与反向解码日志。

### TC15 权限与资源隔离

关联：R04 R06 R07。状态：not_run。

操作与环境：跨project读取、CSRF缺失、路径穿越、恶意HTML、过期lease以及未知设备动作测试。

通过条件：请求拒绝且原材料不泄漏；iframe不能拿宿主session；只有当前lease执行登记动作。

失败/反向检查：未知物理结果不得自动重放flash/write；隔离打开不能以allow-same-origin修复。

提交证据：服务/浏览器安全断言、动作调用计数、租约代次与回执。

### TC16 Store故障与重启

关联：R11。状态：not_run。

操作与环境：在blob rename/journal fsync/index步骤故障注入；删可重建索引；清理workspace；磁盘耗尽。

通过条件：索引重建、孤立blob可回收、尾记录截断有报告；证据不随workspace消失；core可继续。

失败/反向检查：双writer启动拒绝；中段journal损坏停止写不偷偷截全库；pinned材料不自动删。

提交证据：故障点矩阵、恢复hash、锁检测、磁盘与runtime记录。

### TC17 四页视觉基线

关联：R10。状态：not_run。

操作与环境：固定fixture和时间，在1440x900分别截图四页；另截图架构页；1280/1920回归。

通过条件：八卡首屏；Soft Glass tokens一致：正文15px/标题28px、10/16/20px圆角、每区域至多一个蓝色主动作；仅导航轻磨砂、日志不透明；双行导航/账号入口与所有字段保留；架构宿主同风格、图内原viewer。

失败/反向检查：禁止从生成PNG取色/OCR改业务数据、沿用旧14px/小圆角/深灰主按钮或大侧栏；禁止玻璃叠玻璃/透明日志。设备tab使用灰色分段控件，补证据为真按钮；颜色不能唯一表达状态。

提交证据：五页原生截图、2x2总览、与新四张PNG并排对照、实际tokens/字体记录、正文4.5:1及关键边界3:1对比测量、36px按钮/44px触控热区和降低透明度/减少动态检查。

### TC18 页面全状态与键盘

关联：R10 R11。状态：not_run。

操作与环境：各页loading/empty/error/stale/unsupported/denied，键盘完成筛选、评论与候选切换。

通过条件：失败保留输入/旧成功区块；读时间明确；focus返回；日志可选可复制。

失败/反向检查：刷新/后退不丢URL筛选；断线不假在线；隐藏按钮不替代服务鉴权。

提交证据：浏览器自动测试、状态截图、可访问性与键盘记录。

### TC19 性能与理解

关联：R10 R12。状态：not_run。

操作与环境：4vCPU/8GB、100issues/100节点分图/10k日志；至少30次视图/1000条日志样本；工程师完成3项理解任务。

通过条件：记录p95视图≤2s、log接收后≤1s；30s目标阻塞/2导航原件/3min解释取舍。

失败/反向检查：设备到host未知延迟不能算进host指标而声称全链达标；失败结果如实。

提交证据：环境、原始时序样本、计算脚本、理解任务录屏/计时。

### TC20 领域边界

关联：R09。状态：not_run。

操作与环境：在实际repo映射L0–L4来源与目录；评审OS路径、设备路径和runtime契约测试。

通过条件：无语言/OS硬编码；反馈crosscutting；runtime语义用Host+目标同源测试体现。

失败/反向检查：禁止上层裸用底层对象；不强制每条调用经过五层；unknown归属不能猜。

提交证据：实际profile、源码引用、边界检查、目标/Host测试记录。

### TC21 事件恢复与缓存

关联：R11。状态：not_run。

操作与环境：断开LiveView后写新事件，再带cursor恢复；重复event和过期cursor注入。

通过条件：无重复/静默漏事件；过期409重拉快照；tracker/runtime来源时间分别显示。

失败/反向检查：索引重建不得重置project_seq；跨过滤器cursor不得错误复用。

提交证据：事件列表、snapshot_seq、重连断言。

### TC22 物理动作与软件暂停

关联：R05 R07。状态：not_run。

操作与环境：运行受控设备动作后暂停Issue，检查动作独立状态与lease过期。

通过条件：软件停止不伪装物理停止；未知动作进入uncertain/quarantine；恢复先probe。

失败/反向检查：自动重试不能重复非幂等动作；过期owner/generation拒绝新控制。

提交证据：真实可控动作记录、运行/设备双回执、租约/重放断言。

### TC23 干净环境与备份

关联：R12。状态：not_run。

操作与环境：新Linux x86_64及arm64环境按文档安装；demo/live显式启动；备份/恢复工程数据。

通过条件：依赖锁/命令完整；原服务与工作台能启动；恢复后证据hash/链接有效。

失败/反向检查：缺凭证不能回退fixture；架构工具/硬件缺失不宣称通过；不可复现发布为失败。

提交证据：环境版本、完整命令日志、备份校验、已知限制。

### TC24 全链发布

关联：R01 R02 R03 R04 R05 R06 R07 R08 R09 R10 R11 R12。状态：not_run。

操作与环境：真实Issue→Agent→目标板→问题/证据→采用方案→新run→验证→Review/Done，产出真实项目图。

通过条件：所有需求有实现路径+测试+证据；发布包、运行说明、故障恢复和美术验收齐全。

失败/反向检查：静态前端、只有Demo/PTY、只有文档检查、缺一项真实gate都不能标完整发布。

提交证据：release-report、traceability实绩、真实E2E录像和全部hash索引。

Git交付另须满足GIT_ACCEPTANCE.md中的GC01–GC05，作为TC23/TC24发布过程门槛；本包检查器自测通过不代表目标仓库hook/CI或远端保护已启用。

## 证据清单格式

每个TC提交 `test_id / requirement_ids / status / repo_revision / environment_id / command / exit_code / started_at / finished_at / evidence_paths / sha256 / limitations`。一次test可有多个运行，不覆盖过去失败。skipped仅表示未执行；报告不得把它计入通过率。原core已有测试不重复复制，报告其运行命令与结果。

## 阶段出口

M0：TC01基线+TC02/TC20环境；M1：TC03、TC17壳/看板、TC18基本态；M2：TC04–09、TC21；M3：TC10–11/TC15 viewer；M4：TC12–16、TC22；M5：全部回归、TC17–19、TC23–24。受环境阻塞的独立工作可继续，但不越过对应真实发布gate。
