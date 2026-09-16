# M0 环境登记（真实值）

对应任务 T02。本文件记录 **实测** 值，未取得的外部资源一律标 `not_configured` /
`blocked`，不写推测值。模板见 `docs/implementation/config/environment.example.yaml`。

登记时间：2026-09-16（UTC）。登记时仓库 revision 见 `m0-baseline.md`。

## 宿主

| 项 | 值 |
|---|---|
| os | Linux (Ubuntu 24.04.4 LTS, kernel 7.0.0-31-generic, x86_64) |
| architecture | x86_64 |
| cpu | 28 vCPU（宿主可见） |
| memory_bytes | 33243388928 (≈30.9 GiB) |
| elixir | 1.19.5-otp-28（经 mise 安装，`erlang@28.5`） |
| node | 18.19.1 |
| python | 3.12.3 |
| git | 2.43.0 |

Elixir/Erlang 由 `mise` 提供（`elixir/mise.toml` 已锁定 `erlang = "28"`、
`elixir = "1.19.5-otp-28"`）。工具链不在系统 PATH 中时，需把
`~/.local/share/mise/shims` 前置到 PATH，或使用 `mise exec -- make all`。

## Provider

| 项 | 值 | 说明 |
|---|---|---|
| kind | linear | 原仓库默认 adapter，首版工作台 provider |
| test_project_slug | `not_configured` | **blocked**：没有可用的 Linear 测试项目与 token |
| paused_state_id | `not_configured` | 需在真实 workspace 中读取，禁止猜测 |
| review_state_id | `not_configured` | 同上 |

`LINEAR_API_KEY` 在宿主环境中未设置。TC03、TC07、TC08、TC24 的真实
tracker 部分因此为 `blocked`，不是 `passed`。

## Agent

| 项 | 值 | 说明 |
|---|---|---|
| codex_version | `not_configured` | **blocked**：本机未安装可启动的 Codex |
| executable | `not_configured` | 同上 |
| auth_checked | false | 无凭证 |

## 目标项目与设备

`config/embedded-profile.yaml` 的 `project_repository`、`config/devices.example.yaml`
的 `devices`/`image_sources`/`decoders`/`actions` 均为空。真实目标板型号、串口端口、
固件 build/ELF 需要现场登记，本环境无从取得。

因此 TC13、TC14、TC22（真机部分）与 TC24 的硬件链为 `blocked`。开发期用 PTY
（TC12）支撑，PTY 结果不得标记为 `board_run`。

## 数据根与 workspace

`data_root` 必须在 `workspace.root` 之外，由 `Experience.Store.validate_data_root/2`
在启动时强制校验（`:data_root_inside_workspace`）。安全策略、容量与保留期默认值见
`config/devices.example.yaml` 的 `storage` 段。

## 检查状态

| 检查 | 状态 | 证据 |
|---|---|---|
| baseline | `passed` | `docs/verification/m0-baseline.md` |
| tracker_live | `blocked` | 无 Linear 测试项目 |
| agent_live | `blocked` | 无 Codex |
| board_live | `blocked` | 无目标板 |
| dump_live | `blocked` | 无 dump/ELF |
| arm64_install | `blocked` | 本机为 x86_64，无 arm64 运行环境 |

## 凭证处理

只记录环境变量 **名字**，不记录值。tracker token 仅存在于宿主环境/secret provider，
不下发子 Agent，不写入浏览器，不进入实施包。