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

来源读取通过 `UsageStore` 提交采集结果、任务映射和 Fast 证据；目标数据库 SQL 归 `Storage`。所有权判断、报告匹配和证据合并使用调用方的同一事务，文件拆分不改变写锁、批次或断点边界。查询结果类型及行映射与查询 SQL 分开维护。

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

### 3.3 `prices`：按模型／日期／tier 的价格变化

| 字段 | 类型／约束 | 含义 |
| --- | --- | --- |
| `model`、`date`、`tier` | TEXT，非空，联合主键 | 模型、UTC 采集日期、服务档位 |
| `input_price`、`output_price` | TEXT，可空 | 该档位普通输入／输出单价 |
| `cache_read_price`、`cache_write_price` | TEXT，可空 | 缓存读取／写入单价 |
| `long_input_price`、`long_output_price` | TEXT，可空 | 该档位长上下文输入／输出单价 |
| `long_cache_read_price`、`long_cache_write_price` | TEXT，可空 | 长上下文缓存单价 |
| `long_context_threshold` | INTEGER，可空 | 整次输入严格超过此阈值时采用 long 价格 |
| `source_json` | TEXT，非空 | 原始 cost、全部 tiers／modes、上下文规则及直接／推导依据 |

`default`／`standard` 归一为 `standard`，`priority`／`fast` 归一为 `fast`；其他明确档位保留文本。Fast 独立行，其 long 列表示 Fast＋长上下文。不增加 fast_* 列、price_id、currency、pricing_version、pricing_status 或额外生效时间。

### 3.4 `turn_usage`：turn 所有权

| 字段 | 类型／约束 | 含义 |
| --- | --- | --- |
| `id` | TEXT，主键，非空 | 内部所有权关联键 |
| `turn_id` | TEXT，可空，唯一 | 真实 turn ID |
| `thread_id` | TEXT，非空 | 当前最早来源任务 |
| `source_created_at` | REAL，可空 | 来源 session 创建时间，不能用 mtime 或复制后的事件时间代替 |
| `started_at` | REAL，非空 | 可确认的 turn 开始时间；缺失时取该组最早用量时间 |
| `last_event_at` | REAL，非空 | 最后用量事件时间 |

有 turnId 时内部 id 为 `turn:<ID>`；没有 turnId 时使用 `unattributed:<threadID>` 隔离该任务的历史记录。这个内部关联不等于源系统的 turn，也不能据此证明跨任务重复。缺 turnId 的回退分组跨额度窗口时精度有限，不能承诺逐请求归属。

### 3.5 `usage`：逐条有效消耗

| 字段 | 类型／约束 | 含义 |
| --- | --- | --- |
| `id` | INTEGER PRIMARY KEY | 数据库行身份 |
| `account_id`、`thread_id`、`turn_id` | TEXT，可空 | 已明确的账号、任务和 turn |
| `response_id` | TEXT，可空 | 源系统真实响应 ID；不以 turn＋序号伪造 |
| `turn_key` | TEXT，可空，外键 → turn_usage.id | 所有权关联，删除所有权记录时级联删除其用量 |
| `occurred_at` | REAL，可空 | 单条报告的 UTC 时间戳 |
| `usage_date` | TEXT，可空 | UTC 计价日期，与 occurred_at 至少存在一个 |
| `hour`、`minute` | INTEGER，可空 | occurred_at 的 UTC 小时 0–23、分钟 0–59 |
| `model`、`tier` | TEXT，可空 | 已观测模型与服务档位，原始 tier 保留在证据中 |
| `is_long_context` | INTEGER，可空，0／1 | 按单条输入与价格规则得到的上下文分类 |
| `input_tokens`、`output_tokens` | INTEGER，可空，非负 | 输入含缓存，输出含推理 |
| `cache_read_tokens`、`cache_write_tokens` | INTEGER，可空，非负 | 输入中的缓存分项 |
| `reasoning_tokens` | INTEGER，可空，非负 | 输出中的推理分项 |
| `total_tokens` | INTEGER，非空，非负 | 本条有效消耗总量 |
| `input_price`、`output_price`、`cache_read_price`、`cache_write_price` | TEXT，可空 | 实际采用的分项费率，已包含 tier／上下文规则 |
| `input_amount`、`output_amount`、`cache_read_amount`、`cache_write_amount` | INTEGER，可空，非负 | 分项纳美元金额 |
| `amount` | INTEGER，可空，非负 | 所有分项完整可算时的总金额 |
| `source` | TEXT，非空，local／api | 当前日志采集写 local；API 日桶不写入本表 |
| `rollout_id` | TEXT，非空 | 逻辑日志来源 |
| `source_line` | INTEGER，非空，> 0 | 解压后行号 |
| `source_ordinal` | INTEGER，可空，≥ 0 | 上游事件序号，不是轮内响应序号 |
| `evidence_json` | TEXT，非空 | 主报告、匹配的其他报告、累计基线、模型／模式与计价依据 |

没有业务 dedup_key、独立请求金额表、is_fast 或 turn 聚合分项字段。`response_id`、`turn_id` 和 `source_ordinal` 不互相替代；历史无响应 ID 的一行只承诺是一条有效用量，不能断言是一笔独立网络请求。

索引：

- `(thread_id, occurred_at)`、`(account_id, occurred_at)`、`(model, occurred_at)`。
- `(usage_date, hour, minute)` 支持 UTC 时间桶。
- `(rollout_id, source_line)` 是普通定位索引，不能唯一：文件替换后相同行号可能对应不同事件。
- `(turn_key, response_id)` 在 response_id 非空时唯一，约束已明确的轮内响应。
- `(turn_key, json_extract(evidence_json, '$.legacyCumulative.total_tokens'))` 缩小旧报告匹配范围，匹配后仍核对完整累计分项和用量。

主报告存于 evidence_json.report，已匹配的其他报告存于 alternateReports，各自保留行号和 ordinal。计价证据区分 rollout、trace、default_standard；观测 tier 为空时，采用普通费率也不把观测字段伪写成 standard。

### 3.6 `weekly_limit_observations`：七天额度原始观测

| 字段 | 类型／约束 | 含义 |
| --- | --- | --- |
| `id` | TEXT，主键，非空 | 观测身份 |
| `scope_key` | TEXT，非空 | 来源账号或任务范围 |
| `account_id` | TEXT，可空 | 明确账号，不回填猜测值 |
| `limit_id` | TEXT，非空 | 历史只保存主桶 codex |
| `observed_at` | REAL，非空 | 实际观测时间 |
| `resets_at` | INTEGER，非空 | 当时报告的预计截止秒值 |
| `used_percent` | REAL，非空 | 当时使用率 |
| `source_json` | TEXT，非空 | 窗口时长及来源定位等证据 |
| `turn_id`、`exclusion_reason` | TEXT，可空 | turn 身份和已知排除原因 |
| `collected_at` | REAL，可空 | 采集时间 |

索引：`(scope_key, limit_id, observed_at, id)`。完整实时快照不落此表，只有符合主桶七天范围的观测持久化。

### 3.7 `weekly_limit_cycles`：可重建窗口缓存

| 字段 | 类型／约束 | 含义 |
| --- | --- | --- |
| `id` | TEXT，主键，非空 | 查询范围内窗口身份 |
| `account_id` | TEXT，可空 | 可明确归属的账号 |
| `limit_id` | TEXT，非空 | codex |
| `scheduled_reset_at` | INTEGER，非空 | 稳定代表截止 |
| `event_at` | REAL，可空 | 推算起算时间，用于筛选／分页 |
| `query_scope` | TEXT，非空，默认 all | 全局、未知或指定账号 |
| `result_json` | TEXT，非空 | 窗口统计结果和必要来源 |

索引：`(scheduled_reset_at)`、`(query_scope, event_at, id)`。result_json 包含推算开始、首次观测、首次正用量、最后观测／百分比、峰值、冲突与覆盖数量、恢复观测、窗口本地 tokens、完整／已知金额、未定价 tokens 和用量截止。最终百分比无依据时保持 NULL。

### 3.8 `statistics`：日统计缓存

联合主键 `(account_key, date, timezone, dimension, dimension_value)`，五列均为非空 TEXT。

| 字段组 | 列及类型 |
| --- | --- |
| 非空整数 | total_tokens、unpriced_tokens、unattributed_tokens、record_count、unpriced_records（默认 0） |
| 可空 token 整数 | input_tokens、output_tokens、cache_read_tokens、cache_write_tokens、reasoning_tokens |
| 可空金额整数 | input_amount、output_amount、cache_read_amount、cache_write_amount、complete_amount、known_amount |

账号键为 `all`、`unknown`、`value:<ID>`；dimension 为 `all`、`thread`、`project`、`model`，dimension_value 为 `all`、`unknown` 或 `value:<值>`。不能用 NULL 期待复合主键提供正确去重，也不能让业务名称与内部哨兵冲突。

complete_amount 是完整计价记录的金额合计；known_amount 包含可算的部分金额。是否全部完整必须结合 unpriced_records，不能依赖 SQL SUM 忽略 NULL 后的结果。unattributed_tokens 表示缺少 thread 的用量。

### 3.9 内部维护表

| 表 | 结构和职责 |
| --- | --- |
| `statistics_rebuild` | 与 statistics 同列的内部暂存表，没有正式缓存的主键／非空约束，按 timezone 建索引；只供分批聚合及最终发布，不向界面查询暴露 |
| `app_metadata` | key TEXT 非空主键、value TEXT 非空；保存缓存版本、时区、解析／重算进度、同步结果、Fast 补证及游标等内部状态 |
| `grdb_migrations` | GRDB 管理的已应用迁移标识，不手工写入 |

API 日桶表不存在。API 同步摘要（结果时间、账号、桶数量、错误）可以持久化；每日 tokens、账号用量摘要正文和完整实时额度仅在内存中。

## 4. 日志采集与去重

### 4.1 来源身份与压缩

支持 `rollout-<时间>-<thread_id>.jsonl` 和 `rollout-<时间>-<thread_id>_<rollout_id>.jsonl`。普通创建的 rollout ID 通常等于 thread ID；fork 创建新 thread；revert 可以保留 thread、创建新 rollout，因而同任务多文件不一定是 fork。

按规范文件名解析逻辑 rollout，归档位置、inode、mtime 不是永久身份。旧格式无法确认 UUID 时仅使用规范文件名作来源兼容键，不从任意 UUID 片段猜任务。

- 活动和归档目录都扫描。JSONL 普通文件按字节增量读取；半行留到下次。
- `.jsonl.zst` 作为静态表示流式读取，完整扫描且元数据未变后跳过。中断、损坏恢复或表示变化时重扫并按已存事实去重，不对压缩字节使用解压后 offset seek。
- 同目录同名的普通和压缩表示并存时，采用普通文件，不额外全文解压兄弟文件比较；跨目录同身份候选仍需核对内容关系，冲突不能任意选择。
- Codex 冷压缩条件按至少七天未修改；读取可以流式解压，追加前才需物化。TokenTick 不用“七天”判断是否已采集，也不主动压缩／解压替换源文件。
- 截断或替换触发核对和重扫；revert、归档或文件消失不表示此前真实消耗退款。

### 4.2 turn 所有权

按来源创建时间优先扫描，在每条用量入库前查询 turn 所有权。

1. 无所有者时建立记录；相同所有者追加时继续处理新消耗。
2. 其他任务包含同一 turn 且来源更晚／相同，跳过该副本，不插入 usage。
3. 更早来源晚到且两边创建时间可比较时，同一事务删除旧所有者的该 turn 用量、更新所有权，再写最早来源的逐条用量；缓存随事实失效。
4. 缺少创建证据不能用改写后的事件日期认定更早；缺 turnId 的历史不宣称能完整跨任务去重。

不查祖先链，不用 responseId 决定 fork 所有者。

### 4.3 轮内消耗匹配

现代 `token_usage_record` 携带真实响应 ID 和用量，历史 `token_count` 使用累计总量与 last_token_usage。累计快照用于识别重复／回放和匹配证据，不能把每次累计值直接相加。

- 有 responseId 时，在已选所有者内按 turn＋真实 responseId 匹配。
- 重复累计、零增量和不能确认的新基线下降不生成额外消耗，不产生负数。
- 新格式后出现同轮、完整用量分项一致的对应旧报告，按解析状态绑定同一消耗；两种格式的任务累计基线可以不同。
- 旧格式在前时，只有累计、完整用量和 turn 均吻合才补真实响应 ID。不能仅凭 tokens 一样、ordinal 相近或固定时间差合并。
- 数据库对候选再次核对完整累计、tokens、已知模型／tier／响应身份；冲突回滚本批和游标，保留可调查问题。
- 同一消耗只留一条 usage，可保留两份不同 ordinal 的报告证据。不同真实响应即使 tokens 完全相同也分别计量。

### 4.4 模型、Fast 与项目映射

`thread_settings_applied` 在 task_started／turn_started 绑定该轮设置；持久设置变化不追溯修改已执行的 turn。同轮 context 缺 service_tier 时保留已绑定证据，显式 NULL 清除；不能把另一轮或当前登录配置填到历史。

压缩发生在新 turn_context 前且模型存在多个候选时，保留未知与候选证据，不能直接采用新模型。rollout 无 tier 时，从当前 CODEX_HOME 的 `logs_*.sqlite` 读取与 thread＋turn 匹配的顶层 response.create.service_tier 或 TurnInput／UserInput 证据。配置更新 Submission ID 不当 turn ID，正文嵌套字段不作依据。额外日志按文件身份与行 ID 增量读取，DB／WAL 变化触发处理，忽略仅 SHM 变化；后到 Fast 证据重算相关用量。

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

每档位只表达一个长上下文阈值；多有效阈值或无法解释的上下文规则报告 unsupported，不静默选一层。原始阶梯完整留在价格证据中。

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

仅使用 limit_id=codex、durationMinutes=10080 的观测，与 primary／secondary 字段位置无关。

先排除已标记无效点、非所有者的 fork turn、fork 创建时刻附近两秒的复制观测、已过期点以及剩余时长大于七天加五秒的异常点。明确账号同一观测时刻的截止冲突超过 60 秒时排除该组。

1. 按截止排序，只用正用量建立窗口；固定首个截止为锚点，60 秒内归并，不以不断移动的邻居作链式扩展。
2. 选择正用量观测次数最多的截止秒值作代表，相同次数保持先选值。附近 30 秒内的零值可以补充观测范围，但不能建立窗口或改变代表截止。
3. 推算开始 = 代表截止 − 604800 秒。恢复后空闲的零值会滚动，不等于该窗口真正固定后的起算时间。
4. 分开首次观测、首次正用量、最后观测、最后百分比和峰值；同刻最后值冲突则最后百分比为空，不因百分比下降自动拆周期。
5. 账号明确时，正值→不同截止的零值→新窗口较低正值，可关联首次归零观测。它是恢复被观察到的时间，不声称是手动操作时间；无足够证据时不补造。

全局、未知账号、指定账号分别从对应证据重建，不能借全局结果回填账号。日期范围按推算起算时间筛选，包含当前已固定窗口。

窗口本地用量采用 `[推算开始, min(预计截止, 下一窗口推算开始))`。有 turn 所有权时间时按 started_at 归属，否则使用 occurred_at；跨界 turn 整体按开始时间近似。账号筛选只取明确匹配的本地记录。完整金额、已知分项金额和未定价 tokens 分开返回，不能从使用率推导金额。

### 6.3 实时额度

`CurrentLimitSnapshot` 只存内存，保留所有可得类型和真实观测时间。API 优先、无 API 时用日志补充；菜单仅使用当前确认账号的快照，不借用其他账号或已经缺失的窗口。历史持久化只提取主桶七天证据，完整实时快照不从数据库恢复。

## 7. 查询、同步与一致性

### 7.1 时间与统计查询

日统计使用明确 IANA 时区，初次初始化保存系统时区。切换时区只重建缓存，不改原时间和 UTC 分量。UTC 小时桶按 date＋hour、分钟桶按 date＋hour＋minute；其他时区从 occurred_at 派生，不能只调整 hour，夏令时重复小时应按实际桶起始时刻区分。不在相邻分钟之间均摊报告用量。

只有日期无精确时间时，不能换算到其他时区，归未知日期；日期范围不强塞该记录，另外返回 unknownDateTokens。首尾筛选日均包含。

普通总览／每日／任务／项目／模型查询使用日缓存；交叉筛选直接查询事实，不持久化所有组合。各维度是相同事实的不同汇总，不能再相加成全局总量。搜索按标题／ID 普通文本匹配，分页前先排序，相同排序值以分组键或行 ID 保持稳定。明细返回 granularity=usage_event，records 不是保证精确的网络请求数。

### 7.2 自动同步

App 启动全来源同步；FSEvents 文件事件合并 2 秒，本地事件扫描至少间隔 10 秒。监听正常时每 30 分钟核对，监听不可用时每分钟核对；每五分钟独立刷新远端，价格每天成功一次。

同步中只合并待办，不并发启动扫描者。取消后至少 60 秒安静期；休眠暂停，唤醒重绑监听并核对，不重放所有错过的定时任务。环境来源变化时重绑目录。各来源失败独立报告，不抹除其他来源已提交结果。

### 7.3 迁移与可恢复维护

WAL 支持读写并行；App／CLI 使用同一 flock 写锁协调扫描、迁移和维护任务。迁移按 GRDB 编号顺序执行，已发布迁移不就地修改；失败事务回滚，未来 schema 拒绝写入，不自动复制主库／WAL 备份。

当前迁移包含将旧宽价格拆成 tier 行、未上线聚合用量清空后重扫，以及删除旧 API 日桶。这是一条保留的升级路径，不是每次启动清库；价格、任务映射和周额度证据保留。新建库执行完整迁移链，结构迁移与解析版本、计价算法和统计断点分开管理。

用量变化、项目归属变化通过同事务触发器推进事实版本；标题变化不影响金额。窗口缓存同时依赖额度证据版本及用量／计价版本。

- 金额重算每批 512 行，金额与断点同事务提交。恢复核对范围、事实版本、价格／默认 JSON 指纹和内部断点版本；变化则重新核对。自身重算后保存更新后的版本，避免误判自己的写入。
- 统计重建每批最多 8192 行，聚合结果写 statistics_rebuild，断点一起提交；完成后原子发布正式缓存。失败不暴露半成品，依据变化废弃旧进度重新计算。
- 日缓存过期时尝试重建；扫描写锁忙或读快照版本已变化时直接聚合已提交事实，不将旧缓存标成当前值。已迁移数据库的新连接不等待整个扫描完成。
- 设置的容量／旧备份列表只读文件元数据，不扫描全部用量或主动 checkpoint；旧备份不自动删除。

## 8. 上游契约入口

下列链接用于维护时核对来源；实际规则以上述当前约定为准，不把上游未来变化当成已支持功能。

- [Codex rollout 文件名](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/rollout_file_name.rs)、[读取与追加压缩文件](https://github.com/openai/codex/blob/ce2c2759ebee2d64565922f6f7365082284f9570/codex-rs/rollout/src/compression.rs)。
- [models.dev API](https://models.dev/#api)、[价格 schema](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts)、[兼容字段生成器](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/generate.ts)。
- [OpenAI 价格](https://developers.openai.com/api/docs/pricing)、[缓存用量语义](https://developers.openai.com/api/docs/guides/prompt-caching#monitor-cache-performance)。
