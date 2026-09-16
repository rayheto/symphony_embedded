# API、Agent 工具与语义校验

`contracts/openapi.yaml` 为新增 HTTP 契约，实体字段来自 `entities.schema.json`；两者定义一致。HTTP 请求携带 project scope，读取需鉴权，Mutation 经 session/CSRF。实际 session cookie 名称复用当前 endpoint 配置，不因为例子另建登录系统。loopback 单操作者身份由 server 建立；可信远程代理身份需配置代理信任列表，不能相信任意客户端 header。

## 读与写

列表分页上限200，opaque cursor绑定项目/筛选/snapshot；event replay上限500。快照丢效时409 cursor_expired并提示刷新；event有 durable project_seq。默认走 Phoenix LiveView/PubSub 推送同一 Query/Operations 服务，REST不另写业务逻辑。原 `/api/v1` API 继续原状。
所有变更走 `POST /operations` 的 typed action union；202表示受理。mutation expected_revision 指目标本地 revision；create_issue/register_device/source generation 可为null，已有目标不可为null。adopt绑定 Decision，暂停/恢复/改状态绑定 Issue，comment/review/request_evidence绑定指定target，设备动作绑定Device，reconcile绑定Operation。不同目标不能混用revision。
Issue本地revision只是provider投影版本；provider_version单独传入。有provider字段变化才增加投影revision。updated_at不提供远端原子CAS保证。读回确认、部分结果与unknown遵循状态规格。
字段 actor 永远从可信宿主上下文产生；客户端提交 actor 应400。所有ID必须在同一project；issue_id含provider稳定ID，identifier仅人类展示与路由使用。Issue详情路由从identifier解析provider ID，不拿显示编号当跨tracker主键。

| Action | 必须满足的语义 |
|---|---|
| create_issue/change_issue_state | 原生状态/负责人/标签来自当前provider scope；不支持字段明确报错 |
| pause_issue/resume_issue | 已配置非active非terminal暂停状态/合法active目标；禁止以关闭代暂停 |
| adopt_decision | 决定revision有效、option存在、依据版本仍可审阅；resume=true时需合法target |
| adjust_constraints | 草稿仅更新候选约束/修订，不发布执行计划；对已采用决定修改约束则创建新的采用修订并保留选定方案，继承历史，正在running先暂停确认再发布 |
| comment/review/request_evidence | target_type与实际对象一致；review绑定revision；request不暗中恢复任务 |
| generate_architecture | source必须完整revision；delta必须base+head；plan必须plan_revision及材料；建立原tracker架构任务，不启动第二个Agent调度器 |
| register_device | configured_device_key来自宿主可见配置；UI添加表单探测后登记，配置文件更新由宿主执行 |
| connect/disconnect/capture_image | 仅已配置适配器/图像源；disconnect不能被误用作证明物理动作已停止 |
| run_device_action | 当前lease generation与owner匹配，tool allowlist；未知结果先观察，禁止自动重放 |
| decode_dump | 原始dump可用、ELF/hash与实际firmware匹配；unknown/mismatch不产出确定栈 |
| reconcile_operation | 只对账受理过的操作；无法确定时保持unknown，不以查询动作偷偷重做副作用 |

Schema是结构边界；下列关系在服务层测试：byte range start≤end≤blob长度；source_seq单调；同project引用；source_ref行号有效；passed需实际criterion与材料；human接受仅human actor；adopted option存在；plan_loaded必须匹配当前run读到的decision hash；artifact宣称成功时IR/HTML/manifest及必需回执存在。

## Agent 工具

`agent-tools.json` 保存canonical inputSchema与共用definitions，注册时将 `#/$defs` 解析到definitions并转换成当前 DynamicTool 的JSON格式。工具追加到原provider工具集，不替换 `linear_graphql` 或原workpad能力。
工程report由当前run绑定project/issue/actor；不能伪造human verdict。提交revision必须等于expected+1；create expected=0/revision=1。Evidence原始内容不得原地修改，需新ID+supersedes；Case/Decision草稿可新revision；已有人工review投影由server合并，agent的unseen不能清除历史。
Blob import路径必须在当前workspace，处理symlink/containment并校验hash，再复制到data_root。证据工具只有材料持久提交后返回成功。architecture publish需要按manifest全部内容验证，Agent不能仅上传一份成功摘要。plan_loaded从当前workpad读取并校验；该事件不改变core成功条件或测试结果。
工具成功返回 `{ok:true, entity_id, revision, project_seq}`；blob返回 BlobReceipt；读取返回实体；失败 `{ok:false, error: Error}`，wire envelope遵循原app-server工具协议。工程工具失败不伪装成正常记录。

## 上传、下载与隔离

HTTP原始上传以流式写入CAS，默认64MiB单材料上限，可在宿主明确增加；串口大文件按chunk存储。先落temp+fsync+rename，再返回hash，Evidence注册引用已存在blob。断传清理temp；未被引用blob按保留期清理。引用与权限分开：知道hash不授予下载权。原始字节按attachment下载；不将HTML/SVG等任意材料作为可信应用DOM执行。
上传图片可由UI建立Evidence草稿，通过受控的宿主注册服务完成；增加该入口使用同Evidence结构和权限验证，不通过假Agent身份。为避免两套写模型，HTTP注册采用下述 `register_evidence` action（见machine contract），actor由server决定。
Archify viewer走隔离资源发布，API只返回产物元信息与授权的blob下载；隔离URL由LiveView presenter根据部署配置生成，不接收客户端任意iframe URL。

## 设备租约的入口

HTTP `acquire_device_lease` / `release_device_lease`同样走Operation和Device revision；human owner由服务端解析为该用户的操作会话，不能授权任意run。Agent通过engineering_device_lease申请/续租/释放，owner绑定当前run；acquire时generation=null，renew/release必须匹配当前generation。ttl默认30s、范围5–300s；续租只延时，不转移owner或重放动作。失效后重新获取增加generation。串口只读订阅不需要控制lease。宿主进程重启使所有旧控制lease无效，下一代次从持久计数继续，禁止归零误接纳旧token。

## 页面下钻读模型

Issue context提供当前workpad计划引用、Decision/hash与关联Case/Evidence，运行详情使用保留的原runtime入口。变更tab用ChangesView明确base/head/patch范围，原diff作为blob展示和下载；尚无可读取修改时是unavailable，不编造diff。设备“查看构建记录”打开drawer，通过build-records读取有来源的BuildRecord；未知firmware/build关联保留unknown。BuildRecord由宿主构建记录导入或受控adapter产生，不允许浏览器填一个build标签直接证明firmware对应源码。

provider-metadata提供真实状态/负责人/标签，新增表单不可硬编码原型选项。devices/snapshot/provider-metadata的refresh=true仅强制有限频率只读获取，不执行reset/flash。DeviceObservations提供图像源与故障记录入口；set_image_source仅选择宿主allowlist观测源并探测，capture_image才保存不可变帧。连接观测源不代表目标设备通过验证。完整按钮映射见UI_ACTIONS.md。
