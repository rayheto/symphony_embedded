# M5 视觉验收（TC17/TC18）— 证据与状态

状态：**浏览器证据已产出**（此前记为 blocked，原因是环境问题，已定位并修复）。逐张的感知评审
仍属人工/多模态评审范畴，本文件不代它下结论。

## 之前为什么做不了（已修复）

曾记为「Chrome 无法完成任何 http/https 导航」，并把方向指向代理，那是误判。实际原因：

headless Chrome 启动后要向会话 keyring（gnome-keyring，经 D-Bus）索要 cookie 加密密钥。本环境
`XDG_SESSION_TYPE=tty`，该调用不返回，于是 CookieStore 的持久层永远加载不完——NetLog 里只有
`COOKIE_PERSISTENT_STORE_KEY_LOAD_STARTED`，从头到尾没有一次 `..._LOAD_FINISHED`。而
`URLRequestHttpJob` 在 cookie 这一步是同步等待的，结果是**所有带 cookie 的请求（即所有导航）都
永远停在拿到 socket 之前**，且不报任何错。

加 `--password-store=basic` 即恢复。`elixir/scripts/workbench-shots.sh` 与 archify 的
`bin/visual-check.mjs` 都已带上该 flag。

排查中被误读的现象，记下来免得再走一遍：

| 现象 | 实际含义 |
|---|---|
| 服务器侧两次 `ACCEPT` 后 `recv` 返回 0 | 那两个 socket 是 `is_preconnect=true` 的**预连接**，在 +510ms 被 `SOCKET_POOL_CLOSING_SOCKET` 以 `reason="Cert verifier changed"` 清池；**主框架请求从未绑定到 socket** |
| 外网请求也挂住（`example.com`/`neverssl.com`） | 所以与代理、与「本地直连」都无关；走代理的系统请求（`clients2.google.com/time`、组件更新）反而全部成功，因为 `URLRequestHttpJob` 那一步它们不查 cookie |
| `--no-proxy-server`、显式 `--proxy-server`、清空 proxy 环境变量均无效 | 与代理无关的旁证 |

磁盘缓存正常（`HTTP_CACHE_GET_BACKEND`/`OPEN_OR_CREATE_ENTRY` 都完成），`--no-sandbox` 也与本次无关。
判断依据是 NetLog + 自建线程化裸 socket 服务器，复现脚本思路见下。

## 现在可以提交的证据

| 产物 | 说明 |
|---|---|
| `docs/verification/evidence/screenshots/*.png` | `elixir/scripts/workbench-shots.sh` 产出：issues/devices/reviews/architecture/dashboard 五页，1440×900 |
| 同目录 `manifest.txt` | 每页 PNG 字节数 |
| `docs/architecture/symphony-embedded-workbench/architecture.visual-check.{1440x900,2048x1320}.{light,dark}.png` | archify `visual-check` 产出，明暗两套视口 |
| 同目录 `architecture.visual-check.html` | contact sheet |

`visual-check` 退出 0，各视口 `overflowX/overflowY=false`、`readabilityOk=true`、
`viewerChromeOk=true`、`legendDockIntersectionArea=0`。

### 环境修好后第一次采集是失败的，而且是真的缺陷

`--password-store=basic` 之后第一次 `visual-check` 退出 **1**：1440×900 上
`scrollHeight=937 > 900`（1600×1000 也差 19px），1920 与 2048 通过。也就是说，浏览器能跑之后
测出的第一个事实是**这张图在该视口下装不进首屏**，而不是「环境好了所以通过」。

按上游的修复顺序（先压缩间距、删掉真正冗余的内容，再考虑节点与字号）压缩了 IR 的排版节奏：
行距收紧、边界 `pad` 24→18；没有改节点尺寸、字号或拓扑。重新出图后 `deliver` 9/9，
`visual-check` 退出 0，四个视口的 `scrollHeight` 与 `innerHeight` 相等：

| 视口 | 修复前 scrollHeight | 修复后 |
|---|---|---|
| 1440×900 | 937（溢出 37px） | 900 |
| 1600×1000 | 1019（溢出 19px） | 1000 |
| 1920×1080 | 1080 | 1080 |
| 2048×1320 | 1320 | 1320 |

IR、HTML 与回执的哈希随之变化，manifest 与工作台里的产物都是修复后的这一版（交付验收与浏览器
验收在同一版上都是 pass）。

## 已实际看过的部分

`issues.png`（1440×900）确认为真实渲染，不是空白页：标题 “Symphony Embedded Workbench”、导航
（工作台/设备/待审阅/架构）、“运行状态 · 运行中”、看板各列（待办/进行中/待审阅/已完成）与
“最新事件”日志均在位。其余四张只核对了尺寸与字节数，**尚未逐张评审**。

## 仍未完成的部分

- 按 `docs/VISUAL_SPEC.md` / `docs/DESIGN_UPDATE_SOFT_GLASS.md` 逐张做感知评审（需要人或多模态评审者）；
- 1280 与 1920 宽度的回归；
- 键盘顺序、焦点可见、状态形状的交互走查（TC18 浏览器部分）。

因此 TC17/TC18 记为**证据已具备、评审未完成**，而不是通过。

## 没有据此声称的东西

- 没有把「服务器返回 200」当作页面渲染通过。
- 没有用生成的 HTML 反推业务数据或状态。
- 没有降低任何门槛：`make all` 与原有阈值未改动。

## 复现与继续

```sh
elixir/scripts/workbench-shots.sh                 # 默认写到 docs/verification/evidence/screenshots
ARCHIFY_CHROME=/path/to/chrome elixir/scripts/workbench-shots.sh /tmp/shots

# 对着已经在运行的实例取图（例如登记了真实设备清单、发布了真实架构产物的那一个），
# 而不是脚本自己起的临时实例：
SHOT_BASE_URL=http://127.0.0.1:4123 elixir/scripts/workbench-shots.sh
```

若在任何机器上再次遇到「导航无错挂住」，先在 NetLog 里查
`COOKIE_PERSISTENT_STORE_KEY_LOAD_STARTED` 有没有配对的 `..._LOAD_FINISHED`，再查
`SOCKET_POOL_CLOSING_SOCKET` 的 reason——这两条比看代理配置快得多。