# M5 视觉验收（TC17/TC18）— 尝试记录

状态：**blocked**。本环境无法产出浏览器证据。本文件记录实际执行到哪一步、看到什么，
以及为什么停下来，而不是把「跑不动」写成「通过」。

## 已做的事

新增 `elixir/scripts/workbench-shots.sh`：用演示 workflow 启动真实应用，等服务器就绪后由
环境自带的 headless Chrome 按 1440×900 逐页截图，另附 `scripts/workbench_server.exs`
（`--no-start` 起应用，先设定 workflow 路径再加 `--no-halt`）。

脚本本身的启动段是可用的：服务器起来了，`curl` 对 `/workbench/issues` 返回 `200`。

## 阻塞点

Chrome 在本环境**无法完成页面加载**。实测：

| 命令 | 结果 |
|---|---|
| `chrome --headless --dump-dom file://<无外部引用的本地 HTML>` | 0.5s 完成 |
| `chrome --headless --dump-dom file://<交付的架构 HTML>` | 挂住（`fonts.googleapis.com`） |
| `chrome --headless --dump-dom https://fonts.googleapis.com/...` | 挂住，45s 超时 |
| `chrome --headless --dump-dom http://127.0.0.1:4123/workbench/issues` | 挂住，45s 超时 |
| `workbench-shots.sh`（5 页） | 第 1 页截图未返回，300s 超时 |

服务器对同一 URL 返回 `200`，所以不是应用侧问题：Chrome 一旦需要建立连接（字体 CDN 或
LiveView 的 websocket）就停在 `Page.loadEventFired` 之前不返回。这与 M3 里架构产物
`visual-check` 失败是同一个环境限制（见 `m3-architecture.md`）。

因此 TC17（四页 + 架构页 1440×900 视觉基线、tokens 对比度）与 TC18 的浏览器部分
（键盘顺序、焦点可见、状态形状）在本环境**没有实际截图可提交**。

## 没有据此声称的东西

- 没有把「服务器返回 200」当作页面渲染通过。
- 没有用生成的 HTML 反推业务数据或状态。
- 没有降低任何门槛：`make all` 与原有阈值未改动。

## 可以替代提交的证据（已具备）

- 页面的服务端渲染与交互由 `workbench_live_test.exs`（含架构页与产物端点）断言；
- Soft Glass token 值在 `priv/static/workbench.css` 中可逐项核对（正文 15px、标题 28px、
  圆角 10/16/20px、单一蓝色主动作、导航磨砂、日志不透明）；
- 结构与状态都有文字标签，颜色不单独承载语义（卡片/徽章都带文字）。

这些都不是视觉验收的替代品，只是把「已经验证到的部分」与「没有验证的部分」分开。

## 在有浏览器的环境里怎么继续

```sh
elixir/scripts/workbench-shots.sh                 # 默认写到 docs/verification/evidence/screenshots
ARCHIFY_CHROME=/path/to/chrome elixir/scripts/workbench-shots.sh /tmp/shots
```

再按 `docs/VISUAL_SPEC.md` / `docs/DESIGN_UPDATE_SOFT_GLASS.md` 逐张看图，并补 1280/1920
回归与键盘走查。脚本目前只在启动段被执行过；整段流程尚未在本环境跑通。