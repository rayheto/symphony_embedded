# 实际交付验收报告

状态：待实现后填写；此模板不是PASS证据。

1. 发布构建/源码revision/配置hash/基线diff。
2. R01–R12逐项：实现入口、TC、运行日期环境、actual result、evidence URI/hash。
3. core make all、Experience、PTY、浏览器、Archify、真实tracker/Codex/设备的独立结果。
4. Soft Glass四页+架构宿主页截图、1440×900与其它视口、键盘/失败态、对比度/36px控件与44px触控热区、降低透明度/减少动态验收。
5. 实际板型号/固件/ELF/串口/boot/test profile、原始日志/图像/dump与验证局限。
6. 新环境安装/启动/停止、备份恢复及升级回退演练。
7. 未通过/跳过/阻塞及原因；不要归并成overall pass。
8. 可下载构建、校验和、依赖锁、配置、运行手册与已知限制。

最终判断：complete / partial / blocked。只有全部mandatory gate通过才可complete；用户主动改变范围必须引用其决定，不得自行删gate。

Git流程：GC01–GC05结果、提交信息CI与保护规则、原make all/PR head、合并授权来源、land结果和实际merge SHA。检查器自测不能替代远端强制规则核对。
