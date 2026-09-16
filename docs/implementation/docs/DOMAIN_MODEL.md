# 领域模型与五层规则

L0–L4 定义被开发嵌入式产品的职责，语言、OS 与芯片由 profile 绑定。Symphony 自身不按这些层切后端模块。

| 层 | 负责 | 禁止越界 | 典型证据 |
|---|---|---|---|
| L0 Hardware | 原理图、datasheet、pin/lane、电源、时序、内存/面板参数和实测 | 以猜测修改配置、产品业务 | 带页码/版本原理图、测量、厂商资料 |
| L1 OS/BSP | OS配置、板级描述、scheduler、同步设施、device model、build wiring | 产品状态机、器件寄存器实现 | 配置diff、编译、启动、设备枚举 |
| L2 Driver/Hardware Access | 寄存器、DMA/cache/ISR、framebuffer、底层桥接 | 向上暴露未封装硬件指针/对象 | 原始观测、单设备测试、完成事件 |
| L3 Runtime/OSAL | 线程/时间/同步/allocator 与语言运行语义适配 | 混入 UI/网络/存储业务服务 | 标准契约、同源Host/目标测试 |
| L4 Application | 状态机、事件、UI model、service与业务 | 直接接触寄存器/ISR/DTS/硬件时序 | 纯业务测试、目标集成与用户流程 |

OS 路径可 L4→L3→L1；设备路径可 L4→Platform Port→L2→L1/L0。没有 OS 时允许 L2 受控访问 L0。Platform Port 是接口契约，不强制新增层。Feedback/Observability 是横跨五层的观察面，不是 L5。
同层/跨层目录允许声明；一个 Agent 不等于一层。公共配置由 Coordinator 负责整合，不自动阻止所有跨层改动。当前 Zephyr/C/Rust 是示例 profile，禁止作为所有项目的硬编码。实际项目某层不存在时标not_applicable并说明能力归属，不为了凑齐五层新建空模块。

## 工程对象语义

ProblemCase 关联 Issue 和 components，包含症状、假设、实验、方案、下一步。Claim 是可检验陈述；支持/反驳 evidence_ids 可以为空但此时 explicit evidence_missing。Experiment 保存输入、动作、观察、失败与反证；不能用被否定的假设填成根因。
Evidence 是不可变内容及来源；Validation 是用某个标准解释一组 evidence 的结果；Review 是人对具体 revision 的阅读/接受/异议。Decision 是选择方案及取舍，有 draft→adopted/superseded 语义，不与 Validation 合并。
ArchitectureArtifact 存 Archify IR/HTML 哈希、源 revision、generation_kind、manifest 与三种检验状态；组件稳定 ID 不随 label 变化。DeviceSession 保持 device、boot、firmware、capture 时间链；重连可新 capture session，boot 未观测则 unknown，不能凭串口端口名猜。

## 来源与适用范围

Evidence 至少明确 source_kind 和原始定位。firmware 与源码关联不明时字段 null、verification unknown，不能猜。原始记录可有二进制无效 UTF-8，显示文本是带解码策略的派生视图。
`binding` 统一包含 repo_revision、worktree_patch_sha256、build_id、firmware_sha256、device_id、hardware_revision、boot_id、config_sha256、test_profile、criteria_revision；不适用字段为 null，实际需要但缺失的字段进入 limitations。Host测试、QEMU、PTY、真实板卡必须明确区分。
证据有效性变更是新评价状态，不删除历史。实现、验证、人类审阅分别查询，禁止一个 completed 字段代表所有事实。
