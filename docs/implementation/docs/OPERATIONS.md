# 安装、运行与故障恢复手册（实现合同）

本文件指定最终交付应支持的命令与行为。标记“待实现”的命令当前不能在基线仓库直接运行；Agent必须实现并实测后在发布文档移除该标记。已有命令保持不变。

## 已有基线

按仓库mise配置使用Elixir1.19/OTP28。`cd elixir && mix setup` 安装依赖，`make all`执行格式/lint/specs/coverage/dialyzer。`mix build`产生`bin/symphony`；`./bin/symphony /absolute/WORKFLOW.md --port 4000`启用原HTTP。原tag打包平台保持原行为，不因为本扩展随意删除target。

## 要实现的入口

| 命令/入口 | 交付要求 |
|---|---|
| `make workbench-demo`（待实现） | loopback Demo+固定fixture，醒目标识，禁真实tracker/device mutation |
| `make workbench-test`（待实现） | Experience/adapter/helper/PTY契约与OTP测试 |
| `make workbench-ui-test`（待实现） | 浏览器功能、无障碍与视口截图，保存产物 |
| `make workbench-live-test`（待实现） | 明确配置的测试project/设备，真实E2E，缺依赖非成功退出 |
| `/workbench/issues` | 已启用时的任务主入口；`/`仍是runtime |

Python helper依赖和Node/Archify校验依赖分别锁定。`make setup`或文档中的明确bootstrap统一检查；不能依赖Agent家目录未声明环境。生产配置使用`config/WORKFLOW.example.md`和`devices.example.yaml`复制后填写实际ID；示例默认不执行设备写动作。

## 数据与凭证

data_root在workspace之外，仅服务账号可写。tracker token只在宿主环境/secret provider，子Agent仍遵循原过滤；设备工具无tracker token。浏览器不能拿原生token。默认loopback，远程使用TLS身份代理，未经配置拒绝远程写入；不把网络开放误当安全认证。
备份先停止Experience写入/采集或使用一致性快照机制，再保存journal、blobs、architecture和config（排除凭证）；恢复到新目录校验hash再启动。删除workspace不是证据清理。
每次升级备份、校验schema支持范围、检查core spec pin与Archify pin；原数据不可通过静默初始化覆盖。未知schema版本进入只读升级提示。

## 故障定位

| 症状 | 判断及恢复 |
|---|---|
| UI打不开但Agent在跑 | 检查原HTTP端口/LiveView日志，core继续；不重建所有workspace |
| 工单状态无法读取 | 标stale，保留已知界面；变更操作要求refresh；core按原tracker失败行为 |
| 暂停一直等待 | 区分provider写入和reconciliation，确认原snapshot；不显示已停 |
| adopt结果未知 | 查Operation marker/Decision hash/workpad，读回再确认，不再次无脑提交 |
| 串口失联 | 验证端口身份、USB权限/租约、采集会话；报gap并新probe |
| dump无法解码 | 检查firmware/ELF hash及decoder，保留raw；禁止错符号硬解 |
| Archify候选失败 | 看当前候选receipt，不检查last-good冒充新图；按skill有限修复 |
| data_root损坏/满 | 暂停Experience写入和采集，保留core；恢复备份/校验journal，报告缺口 |

## Git质量入口

目标仓库M0按GIT_WORKFLOW.md接入scripts/check_commit_message.py与既有hook/CI；不要覆盖原hook链。检查标题、普通commit范围与实际PR base/head，仍保留原make all。合并继续使用仓库land流程；本包不直接执行远端操作。

## 发布必须附带

可运行构建与校验和、依赖锁、配置模板、启动/停止命令、权限说明、fixture、真实集成记录、截图、R01–R12验收报告、已知限制、备份恢复演练。不能只交源码和“请自行运行测试”。
