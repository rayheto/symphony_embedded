# M5 视觉验收（TC17/TC18）— 尝试记录

状态：**blocked**。本环境无法产出浏览器证据。本文件记录实际执行到哪一步、看到什么，
以及为什么停下来，而不是把「跑不动」写成「通过」。

## 已做的事

新增 `elixir/scripts/workbench-shots.sh`：用演示 workflow 启动真实应用，等服务器就绪后由
环境自带的 headless Chrome 按 1440×900 逐页截图，另附 `scripts/workbench_server.exs`
（`--no-start` 起应用，先设定 workflow 路径再加 `--no-halt`）。

脚本本身的启动段是可用的：服务器起来了，`curl` 对 `/workbench/issues` 返回 `200`。

## 阻塞点

Chrome 在本环境**无法完成任何 http/https 导航**。已定位到可复现的一步：Chrome 会与目标建立
TCP 连接，但在发出任何请求字节前就关闭它。用自建裸 socket 服务器观测：

| 观测 | 结果 |
|---|---|
| 服务器侧 | 两次 `ACCEPT`（预连接 + 请求），随后两次 `recv` 都返回 0 字节——请求头从未到达 |
| Chrome 侧 NetLog | `URL_REQUEST_START_JOB`（main frame）→ `TCP_CONNECT` 完成 → 开始发送请求头，之后没有任何响应事件 |
| `file://` 与 `data:` 导航 | 0.25s 完成（渲染与 `--dump-dom` 路径本身没问题） |
| Chrome 自身的组件更新器 | 同一次运行里成功传输 HTTPS：161KB/2.4s、248KB/0.36s |

**已排除代理**。环境里确实有三层代理配置：`http_proxy`/`https_proxy`/`no_proxy` 环境变量、
gsettings `org.gnome.system.proxy mode=manual`（127.0.0.1:7897）、以及 PAC 端点
`http://127.0.0.1:33331/commands/pac`（返回 `PROXY 127.0.0.1:7897; SOCKS5 127.0.0.1:7897;
DIRECT;`）。但下面这些做法表现完全相同：

- `--no-proxy-server`
- 显式 `--proxy-server=http://127.0.0.1:7897`（本地与远程目标都试过）
- 清空全部 proxy 环境变量 + `--no-proxy-server` + 全新 `--user-data-dir`

对照：`curl` 直连（`--noproxy '*'`）、走 HTTP 代理、走 SOCKS5 三种方式对同一目标都返回 200。

同样无效的还有：`--headless=shell`、`--single-process`（报 V8 Proxy resolver 不可用）、
`NetworkServiceInProcess`、以及关闭后台网络与组件更新的整套 flag。

因此 TC17（四页 + 架构页 1440×900 视觉基线、tokens 对比度）与 TC18 的浏览器部分
（键盘顺序、焦点可见、状态形状）在本环境**没有实际截图可提交**。残留的不确定：从外部只能
证明「连接建立后请求字节没有发出」，无法进一步说明是沙箱拦截还是 Chrome 150 在此内核下的
导航发送路径问题。可用的绕法是在有可用浏览器的机器上跑同一份脚本。

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