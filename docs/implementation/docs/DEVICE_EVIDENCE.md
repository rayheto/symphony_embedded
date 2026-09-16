# 设备适配、采集与证据契约

## 首版必须完成的设备链

一台真实Linux宿主连接一块目标板：登记身份→确认/记录固件来源→单串口采集→原始字节与会话保存→关联Issue验证→断连/重连→租约冲突测试。真实板型号、端口、固件build/ELF由M0环境登记，不从UI示例推断。原型Board-01没有指定芯片。
多模态首版支持用户上传图像及已配置的宿主图像源抓帧（如固定HTTP快照或UVC helper，选一条真实适配路径）；接口同时保留视频/功耗/逻辑分析仪记录上传。dump首版通用原始保存+一个实际目标的已验证decoder。缺少硬件/符号不能算此gate通过。

## DeviceAdapter

能力：probe、open_capture、close_capture、acquire_lease、release_lease、run_action、query_action；只有设备声明的capability可用。原始串口读取与控制串口写要协调所有权，禁止两个进程同时直接读同一端口。
Lease包含resource_id、owner_run_id、generation、expires_at。动作前检查当前generation和owner；续租失败不等于动作停止，标uncertain。恢复需query/实际probe，无法确认时quarantined。SSH worker资源ID包含host identity，端口路径不作为全球设备身份。
动作从allowlist tool_id查宿主配置：可执行文件绝对路径、固定参数模板、timeout、required_capability、idempotent、设备状态前置条件。浏览器/Agent不能注入任意shell或路径。首版动作只在选定目标上验证；reset/flash显示执行前后firmware与boot及结果。

## Python串口helper协议

实现放`elixir/priv/device_helper/`，由Elixir Port启动，stdout只发JSONL，诊断stderr独立；schema见contracts/device-frame.schema.json。依赖pyserial在实际实现中锁定并随release可重建，不要求目标板运行Python。
宿主请求：open(device配置已解析)、close、write（需有效控制租约）、ping。每条有request_id。响应包含request_id、status、error；异步frame带kind、session_id、source_seq、received_at、monotonic_ns、payload_base64；不得把二进制先有损decode。
每帧原始payload上限64KiB，base64 JSONL传输行上限96KiB；read以有限timeout返回，以source_seq保证本采集会话顺序。`gap` frame说明丢失起止序号或unknown count、原因、时间。断连发state disconnected；自动重连只针对采集且重新验证设备身份，不重放write/flash。Port退出由manager报告，原Agent活跃计时独立。
测试用PTY真实字节流模拟USB断连/无效UTF8/突发流，不把PTY标board_run。

## 时钟、chunk与展示

UTC接收时间+宿主单调时间+设备原生时间（若提供）并存。跨源对齐记录误差或unknown；相同boot不证明无丢帧。chunk按8MiB/60s切分，关闭后SHA256、序号范围和字节offset索引。选中日志区间生成Evidence引用不可变chunk范围及上下文，浏览器过滤不更改证据。
图像captured_at是源提供时间，received_at是宿主时间；无法知道前者就null，不能复制后者假装精确。摘要与图像识别是derived artifact，关联原件与生成工具版本。

## Dump

原始dump、固件哈希、build_id、ELF/hash、工具版本、命令参数、exit_code、stdout/stderr均保存。用可配置DecoderAdapter对实际芯片做匹配检查后解码；至少有matched/mismatched/unknown三种build状态。unknown不显示确定调用栈，保留原始材料和缺项。decoder crash不影响core；禁止把空输出标success。

## 风险与失效

设备控制状态与Issue生命周期独立；被暂停的Agent可能已发出持续物理动作。设备页必须表达动作仍在执行/无法确认；机器人急停不依赖UI/LLM。本产品不会通过常规retry再发未知结果动作。
磁盘不足停止新的采集写入并报gap，保留已提交pinned材料。power/USB断开、host重启、固件被外部烧录都需要新probe和证据绑定，旧PASS仅保留历史适用范围。
