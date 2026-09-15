# TokenTick 技术方案

本文记录当前采用的技术结构、数据契约和业务算法，不记录实施过程、测试次数或设备验收历史。产品范围见 [需求](requirements.md)，操作入口见 [README](../README.md)。

## 1. 工程与运行边界

使用 Swift 6、SwiftUI、SQLite WAL。GRDB 7.11.1 和官方 libzstd 1.5.7 通过 Swift Package Manager 管理。Core 不依赖 SwiftUI，不调用外部解压命令。

| 入口 | 职责 |
| --- | --- |
| `TokenTick.xcodeproj` / `TokenTick` target | macOS 26+、arm64 原生 App |
| `TokenTick.xcodeproj` / `tokentick` target | 同平台独立 CLI，入口 `TokenTick/cli.swift` |
| `Package.swift` / `TokenTickCore` | 共享 Core、依赖及测试 |
| `TokenTick/Core` 根目录 | 应用信息、十进制 JSON 证据、服务档位与日期解析 |
| `TokenTick/Core/Collection` | 来源发现、解析、监听与 API 读取 |
| `TokenTick/Core/Synchronization` | App／CLI 共用同步编排与自动同步时间安排 |
| `TokenTick/Core/Pricing` | 默认 JSON、models.dev 解析、单价与金额计算 |
| `TokenTick/Core/Storage` | DDL、采集事务、归属、查询、重算及统计缓存 |
| `TokenTick/UI` | 原生视图、查询结果和应用状态 |

来源读取通过 `UsageStore` 提交采集结果、任务映射和 Fast 证据；目标数据库 SQL 归 `Storage`。所有权判断、请求匹配和结构化字段更新使用调用方的同一事务，文件拆分不改变写锁、批次或断点边界。查询结果类型及行映射与查询 SQL 分开维护。

App 与 CLI 默认共用 `~/Library/Application Support/TokenTick/usage.sqlite`。每次操作调用实时 `getenv` 解析 `CODEX_HOME`，空值回退到 `~/.codex`；单次扫描固定根目录。其他 shell 的 export 不会自动修改运行中进程的环境。

历史明细只在 SQLite 中。内存保存有界解析缓冲、当前批次、分页、统计结果、同步进度及实时 API／额度快照。界面查询不触发全量文件扫描。

## 2. 数据类型与 NULL 约定

- tokens 使用 Int64／SQLite INTEGER，非负；保留源总量，不根据缺失分项补造总量。输入含缓存、输出含推理，缓存和推理不能再加到总量。
- 时间戳使用 UTC Unix 秒；价格与 `usage_date` 为 UTC `YYYY-MM-DD`。业务日统计另带 IANA 时区。
- 单价为美元／百万 tokens，使用十进制字符串 TEXT；金额为整数纳美元，1 USD = 10^9 nanoUSD。
- 缺失的账号、模型、响应 ID、turn ID、ordinal、价格和金额保留 NULL；零与未知不同。
- 来源证据保存统计字段和定位，不复制正文、工具输出、认证信息。
- 表中“可空”针对实际 SQLite 结构；即使历史允许 NULL，新采集也尽量写入已明确字段。DDL 的权威实现是 [StoreSchema.swift](../TokenTick/Core/Storage/StoreSchema.swift)。

## 3. 表结构

### 3.1 `threads`：最新任务映射

| 字段 | 类型／约束 | 含义 |
| --- | --- | --- |
| `thread_id` | TEXT，主键，非空 | Codex 任务 ID |
| `title` | TEXT，可空 | 最新标题 |
| `project_name` | TEXT，可空 | 最新项目名；明确无项目为 `Chat` |

没有独立项目表、project_key、parent_thread_id、项目历史或 updated_at。cwd 仅用于解析项目。用量通过 thread_id 查询最新映射，项目变化使缓存失效，不逐行重写项目字段。

### 3.2 `scan_files`：逻辑 rollout 游标

| 字段 | 类型／约束 | 含义 |
| --- | --- | --- |
| `rollout_id` | TEXT，主键，非空 | 稳定逻辑来源身份 |
| `thread_id` | TEXT，非空 | 来源任务 |
| `file_name` | TEXT，非空 | 排除压缩表示差异的规范名称 |
| `current_path` | TEXT，可空 | 最近可读位置，可随归档改变 |
| `scanned_line`、`scanned_offset` | INTEGER，非空，默认 0 | 已提交完整记录的行号与解压后字节偏移 |
| `last_scanned_at` | REAL，可空 | 最近扫描时间 |
| `file_state_json` | TEXT，可空 | 文件大小、mtime、物理表示及校验信息 |
| `parser_state_json` | TEXT，可空 | 解析版本、会话、模型／tier 上下文、累计基线和双格式匹配状态 |

索引：`(thread_id)`。游标与本批用量在同一事务提交。

扫描断点继续使用 file_state_json 和 parser_state_json，字段不参与独立查询。文件头校验长度由 scanned_offset 推导；解析状态只保留恢复所需的上下文、累计基线与去重状态。settings 仅保存模型和服务档位，不保存来源证据、候选模型或重复的活动设置；继承事件计数仅在本次扫描内存中维护。

### 3.3 `prices`：按模型／日期／tier 的价格变化

| 字段 | 类型／约束 | 含义 |
| --- | --- | --- |
| `model`、`date`、`tier` | TEXT，非空，联合主键 | 模型、UTC 采集日期、服务档位 |
| `input_price`、`output_price` | TEXT，可空 | 该档位普通输入／输出单价 |
| `cache_read_price`、`cache_write_price` | TEXT，可空 | 缓存读取／写入单价 |
| `long_input_price`、`long_output_price` | TEXT，可空 | 该档位长上下文输入／输出单价 |
| `long_cache_read_price`、`long_cache_write_price` | TEXT，可空 | 长上下文缓存单价 |
| `long_context_threshold` | INTEGER，可空 | 整次输入严格超过此阈值时采用 long 价格 |
| `context_rule` | TEXT，非空 | 普通、按上下文阈值或不支持的计价规则 |
| `source_url`、`is_bundled` | TEXT／INTEGER | 价格来源及是否内置 |
| `combination_rule`、`combination_source` | TEXT，可空 | 快速模式与长上下文组合的直接／推导依据 |

`default`／`standard` 归一为 `standard`，`priority`／`fast` 归一为 `fast`；其他明确档位保留文本。Fast 独立行，其 long 列表示 Fast＋长上下文。不增加 fast_* 列、price_id、currency、pricing_version、pricing_status 或额外生效时间。

### 3.4 usage：请求明细

保留请求身份（turn_key、turn_id、response_id）、任务／账号、时间、模型与观测 tier、Tokens 各分项、应用费率和金额分项、rollout／行号／ordinal。

- turn_started_at 与 source_created_at 支持按轮次起点统计和 fork 原始所有权判断，不另设轮次表。
- legacy_total／input／output／cache_read／cache_write／reasoning 保存旧格式累计分项。响应 ID 或完整累计向量用于去重，不只比较总 Tokens。
- reasoning_effort 是独立推理深度字段；pricing_tier、pricing_source 和 price_date 保存实际计价选择，观测 tier 与推断档位分开。
- 不保存 evidence_json、report 或 alternateReports；请求详情展示结构化字段与来源位置。
- 索引覆盖时间范围、任务／账号／模型时间、来源位置、turn_key、响应身份与累计总量候选。

### 3.5 weekly_limit_cycles：已结束额度周期

字段为 id、account_id、limit_id、started_at、scheduled_reset_at、ended_at、reset_kind、last_observed_at、last_used_percent、source_file、source_line、total_tokens、request_count、amount、known_amount。reset_kind 只分 natural／early。不保存结果 JSON、逐次观察或当前窗口。历史周期的用量和费用在同步时聚合落库，页面只读取周期表；补入日志、周期边界变化或重新计价后更新汇总，无数据变化时跳过。

周期用量按同轮次最早的 usage.turn_started_at（缺失时 occurred_at）在开始／结束范围内汇总并保存。当前窗口只保存在进程内，启动时回读源日志恢复。

### 3.6 statistics：日汇总

按 account_key、date、timezone、dimension、dimension_value 唯一保存 Tokens／金额分项及请求数。dimension 为 all／thread／project／model，月／年累加日数据；交叉筛选直接查询 usage。

不使用 statistics_rebuild。全量重建事务内删除并重新插入，失败回滚；日常刷新依据 app_metadata 中的变更日标记仅重算受影响日期。

### 3.7 维护元数据

app_metadata 保存数据版本、时区、价格刷新状态、扫描来源游标等少量维护信息。统计变更日按 UTC 记录，刷新本地日缓存时同时覆盖相邻日期以兼容时区偏移；各时区缓存均更新后清理变更标记。项目归属变化使日缓存全量失效。扫描断点和计价恢复断点保留必要 JSON，不复制到请求明细；价格规则与来源信息使用独立字段。weekly_cycles_revision 记录周期汇总对应的事实版本，版本及周期边界不变时跳过重算。

## 4. 日志采集与去重

### 4.1 来源身份与压缩

支持 `rollout-<时间>-<thread_id>.jsonl` 和 `rollout-<时间>-<thread_id>_<rollout_id>.jsonl`。普通创建的 rollout ID 通常等于 thread ID；fork 创建新 thread；revert 可以保留 thread、创建新 rollout，因而同任务多文件不一定是 fork。

按规范文件名解析逻辑 rollout，归档位置、inode、mtime 不是永久身份。旧格式无法确认 UUID 时仅使用规范文件名作来源兼容键，不从任意 UUID 片段猜任务。

- 活动和归档目录都扫描。JSONL 普通文件按字节增量读取；半行留到下次。
- `.jsonl.zst` 作为静态表示流式读取，完整扫描且元数据未变后跳过。中断、损坏恢复或表示变化时重扫并按已存事实去重，不对压缩字节使用解压后 offset seek。
- 同目录同名的普通和压缩表示并存时，采用普通文件，不额外全文解压兄弟文件比较；跨目录同身份候选仍需核对内容关系，冲突不能任意选择。
- Codex 冷压缩条件按至少七天未修改；读取可以流式解压，追加前才需物化。TokenTick 不用“七天”判断是否已采集，也不主动压缩／解压替换源文件。
- 截断或替换触发核对和重扫；revert、归档或文件消失不表示此前真实消耗退款。

### 4.2 轮次归属

按 turn_key 查 usage 中已有的任务及 source_created_at。不同任务包含同一轮次时，仅采用来源更早的原始任务；原始任务晚到则事务内替换副本请求。无 turn ID 时按任务隔离，不跨任务猜测身份。

### 4.3 请求匹配

同一轮次按 response_id 或完整 legacy 累计分项匹配。匹配后检查 Tokens、已知模型和观测档位是否冲突；冲突回滚且不推进游标。明确响应的报告优先作为来源位置；重复采集只补齐结构化元数据，不保存报告副本。

### 4.4 模型、Fast 与项目映射

`thread_settings_applied` 在 task_started／turn_started 绑定该轮设置；持久设置变化不追溯修改已执行的 turn。同轮 context 缺 service_tier 时保留已绑定证据，显式 NULL 清除；不能把另一轮或当前登录配置填到历史。

压缩发生在新 turn_context 前且模型存在多个候选时，保留未知，候选上下文只用于解析，不能直接采用新模型。rollout 无 tier 时，从当前 CODEX_HOME 的 `logs_*.sqlite` 读取与 thread＋turn 匹配的顶层 response.create.service_tier 或 TurnInput／UserInput 证据。配置更新 Submission ID 不当 turn ID，正文嵌套字段不作依据。额外日志按文件身份与行 ID 增量读取，DB／WAL 变化触发处理，忽略仅 SHM 变化；后到 Fast 证据重算相关用量。

项目映射依次使用明确 projectless 标记、Codex 项目名称、项目根目录文件夹名、可用 cwd 文件夹名。根目录优先于 worktree／源码子目录；多个同深度候选有歧义时保留未知。remote 的 Windows／UNC 路径按原分隔符取名，不当本机路径匹配。

## 5. 价格同步与金额算法

读取 models.dev `api.json` 的 `openai.models`，不混用其他 provider 同名模型，不额外下载相同内容的 models.json／catalog.json。

| 上游字段 | 处理 |
| --- | --- |
| cost.input／output／cache_read／cache_write | 标准档位基础费率 |
| cost.tiers[].tier.type／size 与费率 | 明确的上下文阶梯；这不是服务 tier |
| experimental.modes 中 cost＋provider.body.service_tier | 服务档位独立价格行；无明确 cost 或 service_tier 的 reasoning 模式不作价格行 |
| 模式 cost 中的 tiers | 明确组合费率，优先于推导 |
| context_over_200k | 兼容字段，名称不足以确认阈值；单独出现不硬编码为 200K |

每档位只表达一个长上下文阈值；多有效阈值或无法解释的上下文规则报告 unsupported，不静默选一层。只保存识别出的规则和有效单价，不保存原始阶梯 JSON。

缺明确组合价格时，对输入、输出、缓存读取、缓存写入分别计算：

```text
mode_long_x = mode_x × standard_long_x ÷ standard_x
```

使用同次数据中的分项与阈值。缺任意所需费率或分母为零时该分项为空，不套用其他分项倍率，也不把 Fast 固定为 2 倍。无长上下文阶梯的模型仍使用基础价格。推导值标为估算，不代表上游保证该组合可用。

每天成功同步一次，按 model＋tier 比较最新费率、阈值和实际规则，变化才写当天记录。标准 long 变化会重新推导并比较模式行。失败保留已有数据，不写零价格。同日重新获取需要更新时覆盖同日记录，不定义日内版本。

计价选择同 model＋tier 下不晚于用量 UTC 日期的最近快照；早于首份快照时采用首份。无该模型／档位数据库快照时使用 [默认 JSON](../TokenTick/Core/Pricing/openai-default-prices.json)。已观测 Fast 缺价不能回退 standard；没有模式证据且 trace 也未补齐时才选择 standard，并记录 default_standard。

普通输入量 = 输入总量 − 缓存读取 − 缓存写入。输出已包含推理，不另收推理一次。按单条输入严格大于阈值选择 long 费率，应用于整条用量，不只计超出部分，也不使用 turn 累计输入判断。

```text
分项金额 nanoUSD = 银行家舍入(tokens × 单价 USD/百万 × 1000)
总金额 = 四个已舍入分项金额之和
```

运算使用 Decimal，写入 Int64 前检查范围；整数求和溢出报错，不转换为 Double。零用量金额为零；未知用量或非零分项缺价时金额为空。有一项不完整，总金额即为空，但保留可算分项。输入／输出／总量矛盾、缓存超过输入等情况不能按正常请求计价。

新增快照、默认 JSON 或算法变化标记重算；同步流程检查该标记后重算历史并使缓存失效。独立 `sync-prices` 只同步价格，需 `reprice` 或 `sync` 完成金额更新；普通无变化扫描不触发全量重算。

## 6. API 与额度计算

### 6.1 API 内存日桶

通过短期 Codex app-server 读取 `account/usage/read`；凭据由已登录 Codex 管理。前后读取 `account/rateLimits/read` 核对账号一致性，发生切换则丢弃日桶。

内存持有账号、观测时间和原始每日 date／tokens。显示查询暂按 UTC 日期对齐本地 source=local，覆盖当前明确账号及未知账号用量，并单列未知账号覆盖量；账号未知时只能作全局参考。模型 NULL 及 remote 落盘记录已在本地覆盖量内。

差异为 API tokens − 本地覆盖 tokens；其他参考 tokens 为 max(0, 差异)。不计算金额、不写 usage／statistics，不把差额与本地事实重复求和。API 日期时区和历史账号覆盖尚未明确，因此始终显示 reference estimate。较旧结果不能覆盖新状态；新失败／空值清除旧内存日桶。

### 6.2 历史七天窗口

仅处理 codex 中 durationMinutes=10080 的有效窗口。继承／fork 回放、过期及超过七天加五秒的异常窗口不参与。相同账号、固定截止锚点 60 秒内的记录在内存合并，只保存每个窗口的首末时间及末次比例，不累积原始 JSON。

不同文件可以乱序到达；窗口按首次观察时间排序。新窗口在旧窗口最后观察之后且早于旧计划截止出现时，旧周期以首次新窗口观察时间结束，标为 early；否则到计划截止后标为 natural。无需捕捉零值，也不推断重置卡。

`weekly_limit_cycles` 只保存已结束且观察到正用量的周期。每个文件每个账号的最后额度窗口摘要保存在既有 `scan_files.parser_state_json` 中，与扫描游标和已结束周期在同一事务提交。启动先恢复未归档的窗口摘要，再扫描新增日志，不回读游标前的日志。解析状态升级到 9 时进行一次重扫补齐摘要，之后恢复增量。该摘要只用于历史周期计算，不代替当前登录账号的实时额度快照。

### 6.3 实时额度

`CurrentLimitSnapshot` 只存内存，保留所有可得类型和真实观测时间。总览和菜单仅使用 Codex 当前确认登录账号的快照，不借用其他账号或已经缺失的窗口；日志只有明确匹配当前账号、观测新鲜且未被排除时才能补充，不能用最新历史日志推断登录账号。账号切换清除快照和预测，异步旧结果在应用前再次核对账号。历史持久化只保留主桶七天已结束周期，完整实时快照不从数据库恢复。

App 每两秒只检查当前 CODEX_HOME 与 auth.json 的修改时间、长度和文件身份，不读取凭据正文。元数据变化使 `CurrentLimitSession` 代次递增并清空状态；运行期间空闲时触发 API 核对。请求开始和结果应用前均核对环境，旧代次不能恢复快照，即使账号切换后又切回也一样。账号身份仍来自实时 API 的 accountId，不从文件元数据推断；未确认身份、API 失败或无快照时清空显示。凭据由其他存储管理而未产生文件变化时依靠周期 API 刷新重新确认，不宣称能立即收到所有外部登录变化。

### 6.4 当前窗口预测

`LimitForecastHistory` 是进程内值类型，不落库。先确认当前账号，再接收相同账号的快照；账号改变或退出即清空。按 limit ID＋窗口类型分组，时长必须一致，截止允许相对固定首个锚点 60 秒抖动，不通过连续邻近点扩大容差。缺失窗口从内存移除。

- 拒绝未来、非递增时间和超过 15 分钟的观测。相邻点间隔超过 15 分钟、百分比下降、截止超过锚点容差或时长变化时重新采样，不跨自然重置、提前恢复或长时间空白外推。
- 每组只保存最近 6 小时且最多 360 个点；至少 3 个点、跨度至少 10 分钟才预测。最近点超过 15 分钟后失效。进程重启后重新积累，不读取历史七天记录补造实时样本。
- 秒消耗率 `r = (最后百分比 − 首个百分比) / 观测跨度秒数`，零速度不生成耗尽时间，也不承诺重置时剩余比例。
- `预计耗尽时刻 = 最后观测时刻 + (100 − 最后百分比) / r`；与预计重置时刻比较得到提前耗尽时间。
- `预计重置余量 = max(0, 100 − 最后百分比 − r × (重置时刻 − 最后观测时刻))`。百分比已达 100 时显示已耗尽，不继续预测。
- `进度差 = 最后百分比 − 100 × (最后观测时刻 − 推算开始) / 窗口时长`；推算开始为截止减时长。正值表示超前使用，负值表示相对均匀进度仍有余量。比较时刻固定为最近观测，不将未观测时段描述为实际消耗。

窗口已过期或缺少合理边界时不预测；不足、过期、边界不明、近期零增长、已耗尽和可估计分别返回状态。UI 展示观测时间和估计依据，耗尽时间不承诺未来活动。tokens 与金额不参与以上公式。

## 7. 查询、同步与一致性

### 7.1 时间与统计查询

日统计使用明确 IANA 时区，初次初始化保存系统时区。切换时区只重建缓存，不改原时间和 UTC 分量。UTC 小时桶按 date＋hour、分钟桶按 date＋hour＋minute；其他时区从 occurred_at 派生，不能只调整 hour，夏令时重复小时应按实际桶起始时刻区分。不在相邻分钟之间均摊报告用量。

只有日期无精确时间时，不能换算到其他时区，归未知日期；日期范围不强塞该记录，另外返回 unknownDateTokens。首尾筛选日均包含。

总览以一次刷新固定的 `now` 为右边界：当天取统计时区下的 `[Calendar.startOfDay(for: now), now)`；7／30／90 天及一年取 `[now − 天数 × 86400, now)`，一年为 365 天。当天使用日历计算零点以适配时区及夏令时，不以减去 24 小时代替。`UsageFilters.occurredFrom`／`occurredBefore` 直接过滤事实表的 occurred_at，与账号和其他筛选取交集，不使用完整自然日缓存。摘要、各维度汇总与逐条下钻共用这个范围；缺少精确时间的记录不进入滚动范围，历史总和仍保留。查询拒绝非有限时间戳及反向／空区间，显示日期按统计时区转换。

普通总览／每日／任务／项目／模型查询使用日缓存；交叉筛选直接查询事实，不持久化所有组合。各维度是相同事实的不同汇总，不能再相加成全局总量。搜索按标题／ID 普通文本匹配，分页前先排序，相同排序值以分组键或行 ID 保持稳定。明细返回 granularity=usage_event，records 不是保证精确的网络请求数。

总览使用 `overviewReport`，在同一个数据库读快照内查询摘要、模型、趋势和最近对话。当天及 7／30／90 天按统计时区的日桶统计，一年按周一开始的周桶统计，历史总和按月桶显示。只有日期而缺精确时间的记录沿用既定时区归属规则，不补造小时。最近对话先在所选范围内按 MAX(occurred_at) 排序取 10 个任务，再查询这些任务在相同范围内的汇总；不能先按任务全历史最后活跃排序或对一页明细求和。没有明确任务的用量保留在总览和模型统计中，不伪造最近对话。

总览后台重新查询与 UI 更新分离：数据版本变化或滚动范围边界需要核对时查询，结果未变化不替换显示内容，也不显示后台加载指示；主动切换周期才显示加载状态。主窗口只提供三个页面，明细状态由窗口持有，切换主页面保留筛选／聚合／分页，明细在窗口内弹窗展示，关闭保留原列表查询。设置为独立 scene，主窗口无底部状态栏，上次同步时间与同步按钮位于右上工具栏；同步中显示当前阶段及文件扫描进度，按钮原位显示 loading 并禁用，取消和错误在设置的数据查看。图表轴与数值使用 K／M／B 等十进制单位，金额以 $ 为前缀显示；图表仅为呈现转换成 Double，金额计算与存储仍使用既定精确整数／Decimal 规则。

设置以 NavigationSplitView 提供固定的通用、数据、关于侧边栏，不显示侧边栏显隐按钮。开机启动通过 SMAppService.mainApp 注册或注销，并回读系统状态。App 刷新时将统计时区与系统同步，监听系统时区变更通知后刷新查询；忽略旧的自动同步偏好。

### 7.2 自动同步

App 运行时默认启动全来源同步（开发验证可用 TOKENTICK_AUTOSYNC=0 临时关闭），先请求 API，通过 onCurrentLimits 回调立即发布额度，再扫描日志、同步价格、按需重算金额和更新统计；额度展示不等待整个同步完成。API 失败仍继续处理后续来源。FSEvents 文件事件合并 2 秒，本地事件扫描至少间隔 10 秒。监听正常时每 30 分钟核对，监听不可用时每分钟核对；没有新鲜主额度日志时每五分钟刷新远端；完整主额度日志可将下次请求延后到观测时间的五分钟后，距上次 API 同步开始最多三十分钟。价格每天成功一次。

同步中只合并待办，不并发启动扫描者。取消后至少 60 秒安静期；休眠暂停，唤醒重绑监听并核对，不重放所有错过的定时任务。环境来源变化时重绑目录。各来源失败独立报告，不抹除其他来源已提交结果。

### 7.3 开发阶段重建与维护

当前未上线，StoreSchema 只有 schema.3 建表定义；旧结构直接清空重建，再从源日志重新采集，不维护升级链。WAL 及 flock 协调 App／CLI 写入。

请求及计价变化在同一事务推进统计版本并标记变更日期，项目归属变化使缓存失效。统计重建在一个事务内发布；中断回滚且不保留中间表。交叉筛选、精确滚动时间及缓存不可用时查询已提交 usage。

金额重算仍按批次和已有断点机制处理，区别于不再需要断点的统计缓存重建。关于页只读数据库文件容量，不扫描或展示旧备份。

## 8. 上游契约入口

下列链接用于维护时核对来源；实际规则以上述当前约定为准，不把上游未来变化当成已支持功能。

- [Codex rollout 文件名](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/rollout_file_name.rs)、[读取与追加压缩文件](https://github.com/openai/codex/blob/ce2c2759ebee2d64565922f6f7365082284f9570/codex-rs/rollout/src/compression.rs)。
- [models.dev API](https://models.dev/#api)、[价格 schema](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts)、[兼容字段生成器](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/generate.ts)。
- [OpenAI 价格](https://developers.openai.com/api/docs/pricing)、[缓存用量语义](https://developers.openai.com/api/docs/guides/prompt-caching#monitor-cache-performance)。

窗口材质采用 Surfing 当前源码中的 SwiftUI `containerBackground(.thinMaterial, for: .window)`，无需 NSVisualEffectView／NSWindow 桥接。主额度 codex 优先展示，扩展额度始终展示，同名窗口在卡片内按周期排列。用量视图订阅事实版本与时区变化，同步时间独立更新；总览比较返回内容，查询时间变化但内容相同不替换报告。

趋势改为 Tokens 柱形与金额折线的单图组合，左轴 tokens、右轴美元；仅在绘图时按各自最大值映射到共享画布，tooltip 保留原始值，缺失金额不绘制为零。工具栏同步时间使用独立 ToolbarItem 并隐藏共享背景，显示相对时间。主额度上下排列，进度下方左侧结余、右侧重置；扩展额度仅名称、周期、使用率、倒计时和进度，不显示预测。

### 最新展示约定

- 总览六个周期：当天、7／30／90 天、一年、历史总和。一年是最近 365 天，按统计时区的周一分组；历史按月，其余按日。当天使用零点至 now 的精确区间，其他有限周期使用精确滚动区间，不因日／周聚合扩大数据范围。
- 主／扩展额度共用 `limitsShowRemaining` 偏好；默认剩余，设置可改为已使用。主进度周窗口由 `limitsWorkingDays`（4／5／7，默认 5）控制均分份数，并保留 50%／80% 已用刻度；剩余模式将坐标反转。
- 同账号实时接口的主桶提供 `planType`、`credits.balance`、`credits.unlimited`；根响应的 `rateLimitResetCredits.availableCount` 提供次数，不能用明细数组长度替代。没有套餐倍率字段，不补写 20x。仅保留当前账号内存快照，缺失值不补零。
- 总览趋势按范围内包含的自然日／周／月桶计算平均，包含零用量桶；部分覆盖桶也按一个桶计。费用平均只汇总已知金额。柱形悬停高亮，Tokens／费用各自对应同色平均虚线及均值文字。
- 金额和 Tokens 总量与分项置于同一卡片，模型列表最大宽度 440，列表行距收紧；credits 显示最多两位小数，悬停可读原始余额。

可用重置的到期时间从 `rateLimitResetCredits.credits` 中筛选 `status=available`、`resetType=codexRateLimits` 且未过期的 `expiresAt`，列出已返回明细的所有有效到期时间，重复时间保留；无到期限制显示永不过期。明细可能被上游截断，所以次数始终使用 `availableCount`，不根据数组长度反推次数；缺少明细／日期时不推算到期时间。主额度卡片底部只用普通文本展示，无图标、按钮或重置操作。


### 日志额度优先与 API 兜底

当前登录环境内，API 先确认账号和窗口；之后新日志中周期、重置时间（允许 60 秒偏差）一致且用量不倒退的额度可以更新对应窗口。日志必须晚于当前观测、距现在不超过 5 分钟，排除继承和 fork 回放；登录环境变化立即失效。日志一般没有账号 ID，窗口匹配仅作为本次登录会话中的归属推断，不写回历史账号。新窗口、重置变化及无 API 基准时由 API 补齐。日志未提供的扩展窗口、套餐、可用重置和余额继续保留；预测仅采样实际更新的窗口。

完整主额度日志更新后，将下次 API 同步延后至日志观测时间的 5 分钟后，且距上次 API 同步开始最多 30 分钟，以更新套餐、重置次数、余额和服务端日用量。仅扩展额度更新不推迟 API。没有新的有效日志时保持每 5 分钟 API 同步；启动、手动刷新和登录变化仍主动同步。日志更新沿用文件监听合并 2 秒、扫描最短间隔 10 秒的调度，不增加网络请求。


主额度中 5 小时窗口不显示均分刻度，周窗口按 4／5／7 天设置均分，并保留 50%、80% 刻度。两种窗口均在边界有效时显示当前应使用量的绿色竖线。主额度及扩展额度距重置小于 24 小时时显示“今天／明天 HH:mm 重置”，更远仍显示倒计时。可用重置在主额度卡片内同一行列出接口返回的所有有效到期时间，不再只展示最近一个；credits 同样置于主额度卡片底部。


### 用量明细与套餐用量第二阶段

主窗口持有 UsageDetailsState 和 LimitsPageState，导航切换保留筛选、分页和选中周期。每日点击将日期选择器的起止日期收窄为该日并清除附加 day 条件；项目点击更新 project 条件，之后显示任务。未知日期直接打开请求明细，不建立无法通过日期选择器清除的隐藏条件。任务及统计详情通过固定尺寸的 SwiftUI sheet 打开，详情使用打开时的查询与行快照，关闭不改变主列表。

用量明细和套餐用量共用 UsageDateFilter。固定时间档位显示当天／7天／30天／90天／1年／所有，套餐历史省略当天和7天。自定义日期通过 Menu 中的固定按钮打开锚定日期控件的 popover，重复选择当前自定义项仍可编辑；先写入草稿，应用时更新筛选，取消不提交。主页面不追加日期输入控件。用量明细将聚合切换并入筛选行，日期范围文字置于汇总卡片右侧。总览当天按统计时区零点至 now 查询，其他有限周期保留精确滚动范围；明细和套餐日期范围按统计时区自然日查询。

UsageStore.usageFilterOptions 在一次数据库读快照内返回模型、项目和已识别账号选项。多个账号时提供具体账号和全部账号；只有一个账号则隐藏控件并保持全局查询，不将未知日志回填为当前账号。历史周期列表在多账号时显示已有账号标识。

分页查询在 GROUP BY 之后用 COUNT(*) OVER() 取得总分组数，不拉取全部历史行。超出末页且未返回行时单独查询分组数量；totalGroups 与分页结果采用同一读快照和筛选条件，未知分组也计入。UI 用总分组数计算总页数。UsageReport 解码旧结果时允许没有新增字段。

DashboardModel、统计详情和请求明细保留后台任务句柄，通过取消处理器传播取消，应用结果前再次检查取消与请求代次。请求列表在完整行内容不变时不重新赋值。移除用量明细 inspector 及动态 HSplitView，避免选中行时反复增删原生分栏及重新计算尺寸约束。

周额度只保存已结束的周期，结束边界保留小数秒。requestCount、Tokens 和金额在同步时从 usage 使用相同的轮次起点、周期区间及账号条件汇总落库，页面直接读取；列表保留日期范围；详情标题下显示开始至 ended_at 的时间范围，提前重置在下一行补充 scheduled_reset_at 原定重置时间。界面展示合并卡片、使用比例和必要的提前重置标签，不展示峰值、观察次数或统计依据。

### 总览三环统计

- `OverviewReport` 在同一数据库快照、相同周期内读取模型、互斥使用模式及推理深度分组；沿用有效请求范围和已知金额函数，三组总量保持一致。`hasSameContent` 包含新增维度，数据未变化时不更新界面。
- 推理深度来自 `turn_context.effort`，按当前轮次绑定；新轮次清空，跨轮次请求不继承。持久化在 `usage.reasoning_effort` 中，新数据库从日志直接采集。解析状态升级到 8，旧游标一次性重扫回填并沿用请求身份去重；后续恢复增量扫描。
- 三个 SwiftUI 圆弧组共用画布，独立归一化，固定半径与细描边保持环间留白。按指针半径和角度命中扇区，放大该扇区并联动列表高亮；减少动态效果设置下关闭过渡动画。右侧三组列表横排，窄窗口通过 ViewThatFits 把图移到列表上方，中心留空。保留金额、Tokens 和当前指标占比，各组未知以中性色排最后。

### 项目来源与周期筛选选项

Codex 项目映射读取 local-projects、thread-project-assignments、projectless-thread-ids 和 thread-projectless-output-directories；显式项目归属优先于历史聊天输出目录。无显式归属时仅匹配已保存项目根目录，取消任意 cwd 文件夹名作为项目名的回退。聊天保存为既有 Chat 分组，界面显示“聊天”；无法确认归属保留空值。刷新名称映射不修改请求、Tokens 或计价。

usageFilterOptions 根据查询时区、日期和账号范围，从有效用量事实中取项目／模型去重选项，忽略已选项目、模型和搜索，避免选项互相锁死。界面按日期范围和数据版本重载选项，过期异步结果取消后不写回。

### 窗口激活时更新过期额度

主窗口使用 SwiftUI scenePhase 的 task 在激活时检查当前登录会话快照；超过 15 分钟则保留旧卡片并后台 synchronize(.api)。已有同步时等待其结束，再核对登录环境和快照时效，已更新则不追加请求；离开窗口会取消等待。账号环境变化仍 invalidate，过期预测仍由 LimitForecastHistory 拒绝。无快照的首次启动沿用现有启动同步，不从历史七天数据伪造完整实时快照。


### 总览查询字段优化

- 模式统计使用已有 `usage.tier`；仅当观测档位为空时，通过 `app_metadata` 主键查找对应任务／轮次的 `fast_trace` 记录。明确的普通档位优先于 trace，不把推断值写回观测档位。
- 推理深度统计读取 `usage.reasoning_effort`，不在每次总览查询中解析大段 `evidence_json`；缺失及空字符串仍归为未知。
- `usage(occurred_at)` 索引支持精确滚动时间范围，不修改时间边界、金额口径或请求去重规则。

### 菜单栏与额度时间标记（2026-09-15）

`MenuBarExtra` 使用 `.window` 样式。`MenuBarView` 采用 `.ultraThinMaterial`、固定宽度 320 点及内容自适应高度，不包裹纵向 ScrollView。底部使用统一的 24 点最小行高和固定图标列，hover／按下时整行使用强调色高亮；入口通过 `ApplicationModel.requestedPage` 交给主窗口消费，随后关闭菜单。设置与检查更新仍由 App 原有入口承接。

订阅头部从当前额度快照读取套餐，邮箱仅在 `status.apiLastReport.accountID` 与当前账号一致时显示。当前额度或邮箱缺失且仍在同步时，顶部与额度共用 loading；同步结束后缺失字段不编造。同步状态包含进行中、失败、额度过期及最近同步时间。`CurrentLimitsView(compact: true)` 复用主窗口的数据和进度组件，省略扩展额度，并收紧主额度、重置次数和 Credits 的间距。

`CurrentLimitWindow.usageTicks(workingDays:)` 生成均分刻度及去重后的 50%／80% 刻度。`expectedUsedPercent(now:)` 按 `(now − (resetsAt − duration)) / duration × 100` 计算时间进度；缺少窗口边界、时长无效、非有限时间或 now 不在当前窗口内时不生成标记。`LimitProgressBar` 将其绘制为绿色竖线，剩余模式反转横坐标；4／5／7 天选项不改变窗口时长，也不跳过非工作日。

`MenuUsageView` 查询今天、7／30／90 天摘要，今天与总览共用 `OverviewPeriod.day.query`。总览持久化选择值兼容旧的 `1 天`，显示统一为“当天”。菜单 30 天图表使用 `overviewReport(.month)` 的同一范围和日桶，Tokens 与金额按各自峰值映射到共享画布；缩放下限仅用于防止除零，标题峰值使用实际可用数据，缺失显示未知。

菜单图表隐藏两个坐标轴，另用小字号展示起止日期。保留 Tokens 柱形、已知金额折线与两条平均虚线；平均值为范围内已知总量除以 `max(1, (end − start) / 86400)`，不是只除以有记录的日桶数。金额缺失处断开折线。hover 通过 ChartProxy 把绘图区横坐标映射到日期，并按统计时区匹配日桶；显示柱形高亮、竖向 RuleMark 与不参与布局及鼠标命中的浮层，鼠标离开或视图消失时清除选中状态。金额和 Tokens 浮层保留各自原始单位，不使用映射后的绘图值。


### 单主窗口、快捷键与菜单栏数字（2026-09-15）

主 scene 使用 `Window(..., id: "main")`，菜单及设置入口通过 `openWindow(id: "main")` 打开或复用同一主窗口。启动关闭系统自动 Tab。`TokenTickAppDelegate` 观察普通标题窗口的关闭和成为主窗口通知：关闭时若没有其他可见或最小化的普通窗口，将 activation policy 改为 `.accessory`；普通窗口重新成为主窗口时恢复 `.regular`。关闭最后窗口不退出进程。菜单弹层不作为普通主窗口参与这一判断。

`CommandGroup(replacing: .saveItem)` 显式绑定 ⌘W，通过 `NSApp.keyWindow?.performClose(nil)` 关闭当前窗口。`MainWindowSettingsButton` 同时用于 App 设置命令和菜单弹层内不可见的快捷键按钮，绑定 ⌘,：先恢复 `.regular`，打开主窗口并激活 App，再通过主线程 Task 让出执行后调用 `openSettings()`。设置仍是独立 scene，不作为主页面加入 `AppPage`。⌘Q 使用退出命令，主窗口刷新按钮保留 ⌘R 和同步期间禁用规则；未增加全局按键监听。

`MenuBarExtra` 标签直接使用 `Image(nsImage:)`。从主桶优先选七天窗口，按 `limitsShowRemaining` 转换，限制到 0～100 后四舍五入。101 张数字模板图片在首次使用时创建并缓存，尺寸 18×18 点；一至两位数字使用 7 点粗体等宽数字，三位使用 5.5 点，字距为 −0.45 点。模板图片随系统菜单栏着色。数字随额度或偏好导致的标签更新而变化，不另设标签计时器；重置边界的回退也在标签更新时判断。当前实现没有数字专用悬停百分比提示。

早期标签使用嵌套 `TimelineView` 时，主线程采样持续停留在 `MenuBarExtraHost.requestUpdate`、`MenuBarExtraController.updateButton` 和状态栏按钮布局路径。修复改用直接图片标签与稳定缓存实例；不再在菜单栏标签内部维护周期视图。该结论针对本次 macOS 27 测试环境，其他系统版本尚未复验。
