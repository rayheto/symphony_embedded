# 技术白皮书

## 设计立场

Symphony 将工程师的注意力从监视 Agent 转向管理工作。本产品接受这一立场：Issue 是工作入口，仓库工作流定义自主执行的规则，Orchestrator 管理运行。新增能力使工程过程可以理解、复核和干预，不把所有自动执行变成审批流。

人的认知入口有三个尺度：任务列表处理日常工作，架构图表达关系和变化，调查/证据视图支撑精确判断。图形有利于理解结构，原始日志、实验条件与源码承担无法被缩略图替代的精度。

## 技术选择与依据

已检查的仓库是 Elixir 1.19 / OTP 28、Phoenix 1.8 / LiveView 1.1、Bandit，已有 tracker adapters、PubSub、CSS 静态资源、ExUnit 和 `make all`。沿用这些机制，避免引入第二套 React 服务端、前端状态权威或 Node 调度器。Node 仅作为 Archify 的既有执行依赖及浏览器测试工具，不成为核心控制循环。

新增 Experience 模块将工程记录和读模型暴露给 LiveView。文件证据库位于 issue workspace 外：不可变 blob + 单 writer 的版本化记录 + 可重建内存索引。首版不要求数据库；若规模超出，后续可替换该模块的存储实现而不改变 core。

物理设备通过宿主侧的受控工具访问。串口采用一个 Python/pyserial helper 经 Elixir Port 的 JSONL 协议采集；默认每端口一个采集者，多个页面/Agent 只读共享。工具环境、命令参数与资源由宿主掌握，浏览器不能直接提交任意 shell。

Archify skill 从仓库入口、调用/数据依赖和构建配置编写它自己的 typed IR，然后验证并交付 standalone HTML。工作台保存并呈现产物、来源与回执，不重写 Archify 的图形层，也不修改已通过 deliver 的 HTML。计划图与源码图分别标识；图中路径代表已编写关系，不证明运行时因果。

## 证据与认可

Agent 的结论、人类接受、测试通过是三个不同事实。每个验证绑定源修订、固件、设备、配置与验收标准；更改任何影响条件，原证据仍保留但不能自动支撑新结论。问题记录保存真实尝试和取舍，不要求隐藏推理链或 token 级思想记录。

## 控制与恢复

人类操作通过既有 tracker/workflow/Agent 工具边界生效。暂停默认设置非 active、非 terminal 的状态；原 reconciliation 停止运行且保留工作区。界面只有观察到 worker 停止才显示 applied。单独杀进程不是持久化暂停。
采用方案先记录版本化决定和证据，再更新 tracker workpad 中的计划引用；有待验证的方案可被采用，但其验证状态仍为未通过。新 turn 明确记录已读取的 decision_revision。工作流 reload 只影响其规定的未来边界，不声称当前 turn 自动换了 prompt。
重启沿用原 tracker/filesystem 恢复。工程记录恢复只为显示、核验和操作对账；不重放命令来重建调度状态。

## 范围与代价

首版优先稳定、具体的一条真实使用链。文件存储适合单 writer、小团队，需做磁盘配额、备份和截断恢复；本版没有多写入实例。设备 helper 是明确的边界，但需要打包并验证 Python 环境。Archify 的独立 viewer 有自己的字体和工具栏，宿主不通过 CSS 注入破坏回执；严格像素一致的图形主题定制不属于本版。

## 阅读证据

原仓库与 Archify 精确提交、实际读取路径、附件哈希见 `sources.lock.json`。本白皮书讲设计取舍；行为的规范来源是本包 SPEC、契约与验收文件。
