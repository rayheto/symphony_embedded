# M4 图像与 dump（TC14 的 dump 部分）— 交付记录（部分）

对应任务 T14 中可在无目标板环境完成的部分。只记录 **实际执行** 的结果。

## 交付内容

| 能力 | 入口 | 状态 |
|---|---|---|
| 符号匹配判定（matched / mismatched / unknown） | `Devices.Decoder.match_status/3` | 实现并测试 |
| 受控解码运行（固定参数、超时、崩溃不外溢） | `Devices.Decoder.decode/4` | 实现并测试 |
| 解码器清单（含被关掉的与原因） | `Devices.Decoder.known/1`、`Manager.decoders/1` | 实现并测试 |
| 设备页展示解码器与「不给确定调用栈」的说明 | `/workbench/devices` 概览 | 实现并测试 |
| 原始 dump 作为 Evidence 落盘（字节 + 记录的身份） | `Devices.Observation.record_dump/3` | 实现并测试 |
| 解码结果作为**派生**材料记录（只有真的产出才 available） | `Devices.Observation.decode_dump/4` | 实现并测试 |
| 图像源清单与连接选择（拒绝未登记/被关掉的源） | `Devices.Observation.image_sources/1`、`select_image_source/2` | 实现并测试 |
| 把材料路径交给宿主工具 | `Store.blob_path/2` | 实现并测试 |

## 已验证的行为

- **先判匹配，再动工具**：芯片或 ELF 哈希对不上（`mismatched`）、没有登记芯片或 ELF
  （`unknown`）时，解码器根本不会启动，也就不会给出一个看起来可信却来自另一份固件的调用栈。
- **匹配不等于成功**：匹配通过但解码器非零退出，记为 `failed` 而不是成功；输出为空同样记为
  `failed`——「空输出不算成功」。
- **解码器崩溃不外溢**：工具在独立进程里运行，缺失、崩溃或超时都变成带原因的失败回执，不会
  把调用方带走，也不会变成 `symbolised`。
- **调用方无法拼装命令**：dump 的路径由宿主填进解码器固定参数里的**唯一**一个 `{dump}`
  占位；模板里没有占位或出现多次都直接拒绝，调用方不提供可执行文件、也不追加参数。
- **两个事实分开报告**：`match` 说明符号是否匹配，`decode` 说明这次运行产出了什么，两者互不
  推导。
- **dump 就是字节加记录的身份**：原始字节进内容寻址存储，Evidence 记的是 blob 引用和宿主写下
  的 chip/ELF/build/boot；身份缺项就写进 limitations，不猜、不用空值冒充已知。
- **解码结果是派生材料**：`derivation_of` 指向那次 dump；产出调用栈才记 `available`，被拒或失败
  记 `missing` 并在 limitations 里说明原因——「没能符号化」不会长成一条像调用栈的记录。
- **交出去的是真实存在的文件**：解码前确认材料文件真的在，缺了就报
  `:dump_material_missing`，而不是让工具去抱怨一个不存在的路径。
- **图像源连接是选择不是抓帧**：未登记的 key、被宿主关掉的源都会被拒绝；这里没有任何路径
  会凭空造一帧。

## 未完成与阻塞

| 项 | 状态 | 原因 |
|---|---|---|
| 真实目标 dump 与真机 decoder 验证（TC14 的通过条件） | `blocked` | 没有接入目标板；`docs/environment/environment.yaml` 中 device 身份、固件、ELF 全为 null |
| 图像源**抓帧** | `not_run` | 选择逻辑已验证，但没有可用的宿主图像源（`image_sources: []`），也没有真实帧可绑定；这里不造帧 |
| dump 与 Issue/验证的关联 | `not_run` | 落盘已实现，但需要真实 dump 与运行绑定才能关联到具体 Issue |
| 故障历史与 build 记录抽屉 | `not_run` | 同上，没有真实 build/故障记录可展示 |

因此 TC14 记为 `blocked`：本切片把「不给假调用栈」这条安全性质实现并验证了，但没有真机证据，
不声称这条 gate 通过。

## 门禁证据

命令：`cd elixir && make all`（退出码 0）

| 步骤 | 结果 |
|---|---|
| `mix format --check-formatted` | 通过 |
| `mix specs.check` | 通过 |
| `mix credo --strict` | 0 issues |
| `mix test --cover` | 844 tests, 0 failures, 6 skipped, 100.00% |
| `mix dialyzer` | Total errors: 0 |