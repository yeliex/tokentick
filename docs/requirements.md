# TokenTick 需求与技术方案

日期：2026-09-10

状态：以本地数据正确性为首要验收，当前范围包含内置默认价格、取消迁移备份、额外日志 Fast 证据及普通模式兜底。当前目标及完成门槛见 [执行目标](goal.md)，逐项证据见 [验收状态](acceptance-status.md)。产品名 TokenTick，仓库和 CLI 为 `tokentick`，默认分支为 `master`。

第一版仅支持 **macOS 26.0+、Apple Silicon（arm64）**，不支持 Intel，不保留 Intel 兼容代码。详细实施顺序见 [实现计划](implementation-plan.md)，客户端布局与交互见 [客户端 UI 方案](client-ui.md)。工程骨架不代表采集、数据库或计价功能已实现。

## 1. 定位与边界

为 macOS 上的 Codex 提供可追溯的 token 用量和美元金额统计。数据先行：先保证采集、归属、计价、持久化和重算正确，再基于数据库扩展视图。

- 统计维度：每个任务（thread）、每天、每个项目、每个模型；周额度单独记录重置前观测百分比。
- 本地日志作为请求用量的主要来源；服务端每日 token 总量独立保存，未归属任务时不算入用量统计；额度百分比单独采集。
- 金额是按模型公开价格换算的 API 等值金额，不等同于 ChatGPT 订阅实际账单。
- 完整保存统计相关字段和必要的统计来源证据，不保存对话正文、工具输出或凭据。
- 第一版只支持 macOS 26 及更新版本和 Codex，不建设多 provider 框架、跨平台 CLI 或自有云同步服务。
- 分发参考 Shuttle：App 与 CLI 固定使用 ad-hoc 签名，直接提供 ZIP，不使用付费 Apple Developer Program、不依赖证书或提交 Apple 公证。首次下载后允许按系统“仍要打开”流程确认；未公证不是发布阻塞条件。仍须验证包完整性、独立安装、升级和当前设备运行。最低系统为 macOS 26.0，仅 arm64；按用户要求在当前 macOS 27 设备验收，无需另做 macOS 26 实机验收。
- 数据层保持独立；客户端方案可以迭代，不反向限制已保存的统计事实和查询能力。

## 2. 技术与工程结构

采用 Swift 6、SwiftUI、SQLite，数据库访问和迁移计划使用 GRDB。Swift 能覆盖流式文件读取、JSON 解析、HTTP、并发和命令行；性能首先由读取方式、数据库批处理及索引决定，不预先引入 Rust 核心。

App 与 CLI 位于 `TokenTick.xcodeproj`，以 `TokenTick` 和 `tokentick` 两个 target 编译，共享本地 Swift Package 中的 `TokenTickCore` 模块。Core 源码仍在 App 目录下，不复制业务实现。两个 target 的 `MACOSX_DEPLOYMENT_TARGET` 均为 `26.0`。CLI 入口是 App 目录下的 `cli.swift`，根目录 `Package.swift` 负责 Core 的依赖和测试；不拆独立仓库或另一套 CLI 产品。

```text
TokenTick/
  TokenTickApp.swift       # 仅 App target
  cli.swift                # 仅 CLI target
  Core/
    Collection/            # 文件发现、日志解析、API 同步
    Storage/               # 数据库、迁移、查询
    Pricing/               # 价格同步和金额计算
    Statistics/            # 对账、聚合、缓存维护
  UI/                      # 仅 App target
  Resources/               # 品牌图标、菜单栏模板和界面资源
```

Core 不依赖 SwiftUI。两个入口共用同一个默认数据库、解析器、计价逻辑和查询语义。App 状态主要保存统计结果、当前查询结果及同步进度；历史明细保存在数据库中。解析缓冲、当前批次和详情分页结果允许短暂驻留内存。

使用 Foundation 原生 I/O 和网络能力；需要读取 `.jsonl.zst` 时使用原生 Zstandard 库绑定，不依赖用户安装解压命令。最低系统版本固定为 macOS 26.0；GRDB 和 Zstandard 在对应实现阶段通过包管理工具加入，锁定实际验证的版本。GRDB 已通过 Swift Package Manager 锁定为 7.11.1；Zstandard 使用官方 facebook/zstd 包的 libzstd 1.5.7，已通过 App／CLI 构建与流式解压测试。

## 3. 已核实的两个关键契约

### 3.1 thread、rollout 与文件位置

不能将 thread ID、rollout ID 和文件路径视为同一个概念。

| 操作 | thread 身份 | rollout 身份及扫描处理 |
| --- | --- | --- |
| 普通创建 | 新 thread | 普通文件的 rollout ID 与 thread ID 相同 |
| 继续任务 | 保持原 thread | 按实际发现的 rollout 继续扫描 |
| fork | 新 thread | 新任务的 rollout；复制的历史不能再次计费 |
| revert | 保持原 thread | 可创建独立 rollout ID 的新文件 |
| archive / unarchive | 不应改变统计归属 | 重新发现文件位置，保留已有进度和用量 |
| 压缩 / 解压 | 不改变统计归属 | 同一逻辑 rollout 的不同物理表示 |

Codex 当前文件名解析实现明确区分以下形式：

```text
rollout-<时间>-<thread_id>.jsonl
rollout-<时间>-<thread_id>_<rollout_id>.jsonl
```

第二种形式用于 revert 后保持 thread ID、改变 rollout ID 的情况。因此“同一个 thread 对应多个日志文件”并不等于 fork。此前本机样本中也确认了同一 thread ID、不同后缀 rollout ID 的文件。

扫描记录以 `rollout_id` 为身份；`file_name` 保存规范化文件名，`current_path` 只记录可更新的位置。去掉压缩后缀后再识别同一个 rollout，不能把 `.jsonl` 和 `.jsonl.zst` 当成两笔来源。旧格式不能解析出 ID 时，允许用规范化完整文件名作为兼容键；不能把未验证的 UUID 片段当 thread ID。

归档目录与活动目录都应发现和扫描。发现多个同身份候选文件时先核对内容关系；相同内容不重复入库，冲突内容不能任意选一个。路径、inode 仅辅助查找和检测替换，不是永久身份。

来源：[Codex 文件名解析](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/rollout_file_name.rs)、[recorder 中 revert 的说明](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs)、[压缩文件识别](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/compression.rs)。

### 3.2 models.dev 的 Fast 与上下文阶梯

2026-09-09 已成功请求 `https://models.dev/api.json`，并通过原生 CLI 同步验证：OpenAI provider 返回 48 个模型，44 个具有 token 价格，4 个图像模型缺少 cost。线上响应已确认包含下列基础价格、上下文 tiers 和 Fast 模式字段；此前 403 的调查结论不再作为当前接口状态。

| 数据 | 上游结构 | 处理要求 |
| --- | --- | --- |
| 基础费率 | `cost.input/output/cache_read/cache_write` | 美元／百万 tokens |
| 上下文阶梯 | `cost.tiers[]`，含 `tier.size` 和分项费率 | 优先读取明确阈值；保留全部原始阶梯 |
| 旧上下文字段 | `cost.context_over_200k` | 是兼容输出，名称不能用来判断实际阈值 |
| Fast | `experimental.modes.fast.cost` | 读取 OpenAI provider 的模式价格 |
| 模式请求参数 | `experimental.modes.fast.provider.body.service_tier` | 已核实条目使用 `priority`，供日志模式归一化参考 |

上游生成器保留旧字段兼容消费者，而 `cost.tiers` 携带明确阈值。只解析旧字段会丢失信息。

GPT-6 Astra 的上游 OpenAI 条目示例，金额单位均为美元／百万 tokens：

| 模式 | 输入 | 输出 | 缓存读取 | 缓存写入 |
| --- | ---: | ---: | ---: | ---: |
| 普通 | 10 | 50 | 1 | 12.5 |
| 长上下文 | 20 | 75 | 2 | 25 |
| Fast | 20 | 100 | 2 | 25 |
| Fast + 长上下文 | 40 | 150 | 4 | 50 |

前三行来自 provider 条目；最后一行按该模型官方“Fast 为适用费率的两倍”规则计算，并非 models.dev 显式提供的组合行。该模型的长上下文规则为请求输入超过 272,000 tokens，费率作用于整个请求；不是仅对超出部分加价。不能把倍率或边界条件推广到所有模型。

当前已核对官方价格表中的 GPT-6 Astra、GPT-5.6 Sol／Terra／Luna 组合费率；`gpt-5.6` 是 Sol 的官方别名。仅对这些明确支持的模型，在 models.dev 的 Fast 基础费率确实等于普通费率两倍时计算组合，并保存官方来源和核验日期。GPT-5.4／5.5 的组合字段保持未知。

目前模式价格的 schema 没有嵌套的上下文阶梯，因此仅凭 `experimental.modes.fast.cost` 与 `cost.tiers` 不能通用推导组合费率。优先采用来源直接提供的完整价格；仅对已核实模型使用明确的官方组合规则，保存推导依据；无法确认时留空。不能用其他 provider 的同名模型价格替代 OpenAI 价格。

来源：[OpenAI Astra 条目](https://github.com/anomalyco/models.dev/blob/dev/providers/openai/models/gpt-6-astra.toml)、[价格 schema](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts)、[兼容字段生成逻辑](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/generate.ts)、[API 构建入口](https://github.com/anomalyco/models.dev/blob/dev/packages/web/script/build.ts)、[官方 Astra 定价](https://developers.openai.com/api/docs/models/gpt-6-astra)、[官方 Fast 价格表](https://developers.openai.com/api/docs/pricing)、[缓存计费公式](https://developers.openai.com/api/docs/guides/prompt-caching#monitor-cache-performance)。

## 4. 数据结构

业务主体采用七张表，另有数据库内部迁移、同步元数据和统计恢复暂存表。以下为逻辑字段定义，当前正式 DDL 见 `StoreSchema.swift`；接口证据未满足的字段继续保持未知。

### 4.1 `threads`：最新任务映射

| 字段 | 含义 |
| --- | --- |
| `thread_id` | 主键，Codex 任务 ID |
| `title` | 最新标题，可空 |
| `project_name` | 最新项目名，可空 |

只作 Codex thread 元数据缓存。不新增 `project_key`、项目历史、`parent_thread_id`、`updated_at`。`cwd` 可用于解析和识别项目，不作为必须持久化的统计字段。

项目名变化后，历史用量按最新映射重新归类。同名项目合并，未知项目用 NULL，不能伪造名称。父子及 fork 标记在解析需要时保留到来源证据中，不要求产品建任务关系图。

### 4.2 `scan_files`：每个逻辑 rollout 的扫描状态

| 字段 | 含义 |
| --- | --- |
| `rollout_id` | 稳定身份和主键；旧格式兼容键按 3.1 处理 |
| `thread_id` | 该文件所属任务 |
| `file_name` | 规范化文件名，排除目录和压缩表示差异 |
| `current_path` | 当前可读位置，可空、可变，不作为身份 |
| `scanned_line` | 已提交的最后一条完整记录所在行 |
| `scanned_offset` | 已提交位置；明确为解压后字节偏移 |
| `last_scanned_at` | 最后扫描时间 |
| `file_state_json` | 大小、修改时间、物理表示及必要校验信息 |
| `parser_state_json` | 跨批次需要的累计 token 基线、当前模型等统计上下文 |

扫描状态与本批用量在同一事务提交。半行写入保留到下次读取，不能提前推进游标。普通文件按字节增量定位；压缩文件作为静态表示，首次流式扫描，完整扫描且元数据未变化后直接跳过。压缩文件中断／损坏后的重试、物理表示变化或解析器升级采用重扫与请求去重，不维护压缩流追加游标，也不把解压后偏移用于压缩文件 seek。

同目录下规范化名称一致的 `.jsonl` 和 `.jsonl.zst` 并存时，遵从 Codex 的普通文件优先规则，不对压缩兄弟做全文解压／哈希比较。其他目录出现相同 rollout ID 的多份文件仍需核对，不能未经确认任选其一。Codex 的冷文件条件是至少 7 天未修改，不是读取／访问时间；读取可直接流式解压，只有追加写入前需要物化为普通文件。因此 TokenTick 不按“7 天”推断文件是否已采集，也不修改 Codex 的压缩状态。

已核对上游实现：[读取与追加解压](https://github.com/openai/codex/blob/ce2c2759ebee2d64565922f6f7365082284f9570/codex-rs/rollout/src/compression.rs#L41-L128)、[冷文件判断](https://github.com/openai/codex/blob/ce2c2759ebee2d64565922f6f7365082284f9570/codex-rs/rollout/src/compression.rs#L721-L745)、[普通文件优先与流式读取](https://github.com/openai/codex/blob/ce2c2759ebee2d64565922f6f7365082284f9570/codex-rs/rollout/src/compression.rs#L1003-L1091)。

文件替换或截断触发核对／重扫，不直接减去历史金额。revert 不代表此前真实请求退款。源文件归档、压缩、删除或暂时不可读时，保留已确认的历史用量。

### 4.3 `prices`：按日期保存模型价格变化

主键为 `(model, date)`，日期固定按 UTC 记录价格采集日。每日成功同步一次；应用关闭期间不承诺采集，恢复运行后检查当天是否已成功同步。

| 字段组 | 内容 |
| --- | --- |
| 身份 | `model`、`date` |
| 普通价格 | `input_price`、`output_price`、`cache_read_price`、`cache_write_price` |
| Fast 价格 | 上述四个字段加 `fast_` 前缀 |
| 长上下文价格 | 上述四个字段加 `long_` 前缀 |
| Fast + 长上下文价格 | 上述四个字段加 `fast_long_` 前缀 |
| 阈值 | `long_context_threshold`，含明确的边界语义 |
| 来源 | `source_json`：相关原始价格、全部 tiers、模式信息及组合推导依据 |

首版扁平列适配已核实的单个长上下文阈值，原始阶梯完整保留；若出现多个有效阶梯，不能静默选一档，应按实际样本升级计算结构。价格表不包含 `price_id`、`currency`、`pricing_version`、`pricing_status`，也不区分 observed/effective 时间。

仅价格、阈值或实际计价规则变化时新增记录，不因名称、字段顺序变化插入。当天已成功同步不重复写同日版本；不定义日内价格历史。失败不能写零价、清空旧记录或标记同步成功。

请求计价选择 `date <= 请求 UTC 日期` 的最近一条记录，再按模式与阈值选费率。若请求早于该模型首份快照，允许使用首份快照计价；不修改快照的真实采集日期，也不声称它是历史当天的实际价格。后续日期仍匹配当时最近快照。新增价格、规则升级或中断恢复时重算历史，平常本地增量不全量重算。

代码随 App／CLI 分发 `Core/Pricing/openai-default-prices.json`，维护已核验的 OpenAI token 价格、模型快照名称及官方来源；目前包含 65 个模型／快照条目，覆盖 models.dev 目录和 GPT-5.1／5.2 Codex 等已移出目录的旧模型。数据库价格历史优先；数据库没有对应模型或该模型快照全部费率均缺失时使用内置默认价，包含早于核验日的历史请求。内置核验日不代表历史生效日，金额仍是估算。未知模型及未公布的费率保留空值，不按名称前缀猜价。JSON 内容变更触发可恢复的历史重算；离线也可应用默认价，不要求价格接口成功。请求证据记录实际采用的来源、日期及是否内置。

### 4.4 `usage`：用量事实、所用单价和金额

| 字段组 | 内容 |
| --- | --- |
| 行身份 | 内部 `id`、唯一 `dedup_key` |
| 请求归属 | `account_id`、`thread_id`、`turn_id`、`request_id`／`response_id`，不可得时为空 |
| 时间 | `occurred_at`；只有日期的既有来源使用 `usage_date`，不伪造请求时间，不新增 API 日差额 |
| 模型和模式 | `model`、可空 `is_fast`、可空 `is_long_context` |
| token 明细 | `input_tokens`、`output_tokens`、`cache_read_tokens`、`cache_write_tokens`、`reasoning_tokens`、`total_tokens` |
| 采用的单价 | `input_price`、`output_price`、`cache_read_price`、`cache_write_price` |
| 金额 | `input_amount`、`output_amount`、`cache_read_amount`、`cache_write_amount`、`amount` |
| 证据 | `source`（local／api）、`rollout_id`、`source_line`、`evidence_json` |

`evidence_json` 仅保存统计事件、定位信息、模型／模式依据、必要历史所有权标记，不保存包含正文的整段日志。来源文件位置通过 rollout 扫描记录查询；证据可保留采集时文件名，文件搬迁不改变用量身份。

输入和输出列保留来源对应的总量语义，缓存和推理属于分项；公式中的可计费输入必须按对应日志契约扣除已包含的缓存部分。不能把所有 token 列直接相加。请求级、新旧累计事件都要保留必要证据，但同一实际消耗只形成一份可统计用量。

只保留一个 Fast 标记，不再重复增加 `service_tier` 业务列；原始返回值可保留在统计证据内。长上下文标记表示该请求触发高档计价，不表示模型的最大上下文能力。Fast 来源未知时原始 `is_fast` 保持 NULL，但计价按普通模式；长上下文仍须依据模型规则与输入量判断。

Fast 判定优先使用 rollout 明确值；缺失时只读当前 CODEX_HOME 下 `logs_*.sqlite`，从 websocket 的顶层 `response.create.service_tier` 或 `TurnInput`／`UserInput` 提交补齐相同 thread ID + turn ID 的 Fast 证据。仅配置更新的 Submission ID 不当作轮次 ID；正文嵌套字段不作依据。仍无证据则按普通费率计算，不因缺 Fast 单独标为未定价。统计证据区分 rollout、trace 与 default_standard，保留 trace 文件名、行 ID 和观测时间，不复制请求正文。额外日志按文件身份和行 ID 增量读取，证据及游标同事务保存；后到的 Fast 证据重新计算对应轮次，重复读取不重复计量。监听数据库及 WAL 变化，忽略仅 SHM 变化。

模型无法取得的记录保持 `model = NULL`，模型维度统一显示为“其他”，继续参加 token 汇总；不是必须补齐模型的待办，也不凭模型缺失推断设备来源。已有任务映射保留，无法绑定任务的 API 数据允许 `thread_id = NULL`。

无价格的非零用量，对应单价及金额为 NULL。零用量对应金额为零；有任一非零分项无法计价时，总金额为 NULL，仍保留可算的分项金额。不设置独立 pricing_status。

用量记录保存当次采用的单价，支持直接解释金额；价格表保存日期规则。明确重算时同时更新用量单价、金额及受影响统计。金额统一采用整数纳美元（1 USD = 10^9 单位），用十进制计算后按约定的银行家舍入写入；单价保存十进制字符串，禁止 Double 累加金额。

### 4.5 `api_daily_usage`：服务端每日总量缓存

逻辑主键 `(account_id, start_date)`；账号允许 NULL，通过表达式唯一索引防止未知账号日桶重复。保存 `start_date`、`tokens`、`fetched_at`；保留接口返回的日期，不擅自转换成机器本地日期。API 摘要统计响应保存在内部同步元数据，避免复制到每天一行。

真实接口 `account/usage/read` 的每日桶提供 `startDate` 和 `tokens`，日桶可能为空，不包含模型、token 分项或金额。接口摘要还可包含累计 tokens 等统计。Codex CLI 0.152.1 的本机生成 schema 和实际响应均已核验；2026-09-09 返回了 196 个日桶。响应不提供日桶时区／token 定义，也不直接带账号 ID。通过前后两次 `account/rateLimits/read` 返回的一致账号关联本次缓存，两次均未知时以 NULL 保存，观测期间账号切换则丢弃本次无法归属的日桶。[App Server 文档](https://learn.chatgpt.com/docs/app-server)

该版本还支持按 threadId 请求 `threadUsage`，包含模型分组、speed 和服务端 estimatedUsage 字段；本次账号级查询返回 null。该估值不等同于 models.dev 历史价格换算，暂不混入请求金额。完整统计响应保存在内部同步元数据，为后续核对保留依据。当前实际账号级响应没有金额字段，不能宣称 API 会自然补齐未知金额。未来仅在接口提供同账号、同时间桶、同统计口径的可比总量后，以差额补到“其他”；不能将 API 总量与已入库的本地／remote 落盘记录直接相加。

当前不创建日差额用量。API 日桶无法对应任务时独立保存，不算入全局、任务、项目或账号用量汇总；后续取得明确归属及可比口径再另行扩展。不把未知任务来源等同于其他设备，也不从日总数推算金额或小时分布。

API 同步状态单独保存结果时间、确认的账号与错误，不被后续本地同步覆盖；完整失败和部分可用都能诊断，取消不伪装成 API 故障。旧观测不能覆盖较新状态，旧格式缺少账号／时间则保留未知。菜单只使用最近 API 状态确认账号的最新额度，其他账号的历史仍可独立查询。当前对账证据与缺口见 [API 日用量对账核验](api-reconciliation.md)。

### 4.6 `weekly_limit_observations`：历史周额度证据

只持久化时长为 10,080 分钟的周额度观测，不依赖 primary／secondary 名称判断。历史从日志回填，运行期间优先用接口取得账号明确的观测，日志补充。两种来源都保存观测时间、原计划重置时间、已用百分比和来源证据。

字段：`id`（稳定去重键）、`scope_key`、可空 `account_id`、`limit_id`、`observed_at`、`resets_at`、`used_percent`、`source_json`。日志证据包括文件名、行号；与扫描游标同事务提交。没有账号证据的日志按 thread 分开保留，不能用当前登录账号补归属或跨任务累计百分比。

查询按同一来源归属和额度桶的时间线识别重置：跨过原计划边界且重置时间推进为自然重置；原计划边界前账号明确且额度回落标记为疑似手动重置，即使两次重置时间相同或已产生新用量也保留候选；其他无法确认归属的回落保留待确认。仅重置时间漂移、百分比未回落且未跨过原计划边界时，只保留观测，不生成历史重置。单次观测不构成已完成周期。返回重置前最后观测的百分比及时间，而不是伪造最终百分比或精确手动重置时刻。乱序回填会重新计算相邻关系；持续为零但重置时间随查询漂移时不宣称发生手动重置。

历史查询支持账号（含未知）、额度桶、重置日期和稳定分页。日期按选择的 IANA 时区解释，含首尾日期。不同任务的未知账号观测可以重复反映同一账号周期，不能相加；本阶段不从百分比推算 token 或金额。

**当前实时额度**另用内存 `CurrentLimitSnapshot`，包含接口／日志的全部可获取额度类型、观测时间、账号及完整来源 JSON。所有额度桶的主／次窗口直接展示，附加类型保留原始响应以便核验。五小时额度不进入历史表；当前快照不写同步报告或数据库，也不在重启后伪装成实时值。接口失败保留旧内存观测及其原时间；没有接口观测时可展示新扫描日志的观测。`current-limits` 显式联网返回快照，`limits` 只读历史。

v5 迁移不创建备份，将旧 `limit_windows` 中周额度转为观测，删除五小时历史及旧实时快照元数据，允许 API 日桶账号为空，并使统计缓存失效。旧程序不得写入新结构。

### 4.7 `statistics`：可重建统计缓存

第一版按日保存全局、任务、项目及模型维度的聚合；时间范围汇总从日缓存求和，细分交叉查询可以直接执行 SQLite 查询，不预计算所有维度组合。

| 字段组 | 内容 |
| --- | --- |
| 缓存键 | `account_id`、`date`、`timezone`、`dimension`、`dimension_value` |
| token 统计 | 总 tokens 及可得的输入／输出／缓存／推理分项 |
| 金额统计 | 已知分项金额、完整计价请求金额 |
| 完整性 | 未定价用量、未归属用量、必要的记录数量 |

全局、任务、项目和模型行是同一事实的不同汇总，不能相加成总量。全局保留账号未知的本地用量；按账号查询仅包含明确匹配的用量。未归属任务的 API 用量不参与统计；总 tokens 可能大于已知分项之和。SQL `SUM` 忽略 NULL，不能以求和成功判断金额完整。

SQLite 中 NULL 不自动提供期望的复合唯一性；全局／未知维度使用明确的内部键约定或对应唯一索引，不依赖可空列阻止重复缓存。

实现约定：账号键使用 `all`／`unknown`／`value:<ID>`；维度值使用 `all`／`unknown`／`value:<实际值>`，实际名称与哨兵不会冲突。未归属 tokens 指缺少 thread 的用量。另保存已知总金额 `known_amount` 和未完整计价记录数 `unpriced_records`；非零分项缺失时不能因其他零分项而生成零总金额。明细可保留未归属 API 记录用于核验，汇总排除这些记录。

v3 迁移通过数据库触发器在用量变化和项目归属变化的同一事务内推进事实版本；每个时区缓存记录其事实版本。标题变更不影响统计。重建事务失败保留原缓存与版本，查询不把旧版本当最新值。读快照发现版本过期时直接聚合事实；扫描写锁繁忙时已有连接和新进程均可读取已提交事实。已完成迁移的数据库初始化不等待扫描锁；需要迁移时仍在锁内重新检查迁移状态，不能沿用锁外检查结果执行结构变更。

v4 迁移新增内部 `statistics_rebuild` 暂存表。重建每批最多聚合 8,192 条事实，同事务保存中间结果与按时区的断点；事实版本或断点格式变化时废弃旧进度。全部批次完成后才合并并原子发布正式缓存与版本，查询不读取暂存。最终发布失败也保留已完成进度。恢复规则和进程终止验证见 [维护任务恢复](maintenance-recovery.md)。

## 5. 采集、归属和同步规则

### 5.1 本地采集

- 每次开始文件操作时从进程当前 `CODEX_HOME`（实时 getenv）取目录，未设置或为空时使用 `~/.codex`；不提供目录配置或 `--codex-home` 参数。一次扫描固定其开始时的根目录，避免中途混用来源；监听器定期检查当前环境并重绑定。后续在其他 shell 中 export 不会自动修改已运行进程的环境。
- 发现活动与归档 rollout，包含 JSONL 与 Zstandard 压缩文件。
- 流式逐条解析，限定读取缓冲及入库批次；超长的非统计正文记录可跳过，不整行长期驻留内存。
- 文件通知仅作为增量扫描提示；启动和恢复运行时重新核对目录，弥补漏通知。
- 明确请求级记录、累计 token 快照和上下文 token 数的区别；上下文长度不等于本次计费用量。
- 优先处理有请求／响应 ID 的用量记录，旧格式按经过样本验证的规则回退，不能把新旧事件同时相加。
- fork／revert 的复制历史依据请求身份、源所有权和历史边界去重。累计值减少不能直接产生负数或默认为新请求。
- 时间、模型和观测模式无法恢复时保留未知。不能用当前配置给数月前请求补模型或 Fast 状态；缺少 Fast 证据只影响计价选择，按普通模式兜底并记录依据。
- 读取历史 `thread_settings_applied`，核对 thread 所有权和继承边界；在 `task_started`／`turn_started` 时绑定该轮设置。持久设置更新不追溯改变正在执行的轮次。后续同轮 `turn_context` 缺少 service tier 字段时保留已绑定证据，显式 NULL 则清除；不同轮次不能沿用。
- 前置压缩可能早于本轮 `turn_context`，且模型切换时可能使用上一模型；存在多个候选时保留未知模型及候选证据，不能直接采用新设置。模型、模式证据各自保存来源 rollout、文件名和行号。
- 解析修复可幂等补齐旧用量的未知归属并重新计价，保留原 token 事实与请求身份。旧累计事件因遗漏开始事件而错位的轮次可依据明确证据修正并留痕，但旧去重键保持稳定；其他已知归属冲突须回滚并报告。

### 5.2 身份与证据

请求去重优先使用源系统可用的稳定请求／响应 ID。文件名、行号、token 数组合不构成可靠的跨文件请求身份；没有稳定 ID 的旧记录必须采用经验证的来源边界规则。

不为“完整保留数据”复制整个 Codex 日志。保存足以支持重新计价、归属核对和累计差分的统计字段；源日志以后删除时，已经保存的数据仍能重建统计，未曾采集的信息不能承诺恢复。

### 5.3 时间与网络同步

事件保存 UTC 时间戳，日统计使用明确的 IANA 时区，默认采用首次初始化时的系统时区并记录。切换统计时区只重建日缓存，不改变事件时间。价格日期始终使用 UTC，API 日期语义未验证前不用于跨设备差额。

日期筛选使用所选统计时区，首尾日期均包含；分页顺序稳定。只有 UTC 日日期而无精确发生时间的已入库记录，在其他时区不能精确换算，归入未知日期。带日期范围的查询不把这些记录硬塞进范围，另返回该账号范围下的 `unknownDateTokens`，不声称它们属于所选日期。

价格同步每日一次，失败可有限重试；额度和日用量按应用运行状态节制刷新。App 默认启用自动同步，可在设置中关闭：启动执行全来源同步，文件事件合并 2 秒后触发本地核对，事件触发的本地扫描至少间隔 10 秒；监听正常时每 30 分钟兜底核对，监听不可用时每分钟核对，远端每五分钟单独刷新（不顺带扫描日志），价格仍按每日成功一次去重。正在同步时合并触发，完成后处理待办，不并发创建多个扫描者。取消后至少 60 秒不自动重启；休眠期间暂停计时，唤醒后重新监听并补扫，不重放所有错过的周期。通知失效时保留定时核对，目录恢复后重试监听。应用关闭不承诺持续采集额度历史；首版不额外建设常驻 daemon。CLI 可显式执行同步。

## 6. 数据一致性、迁移与维护

- SQLite 使用 WAL 和事务；App 与 CLI 的写入／扫描／迁移使用共享的跨进程协调，不能只靠进程内 actor。
- 每批解析结果、扫描进度、受影响日统计同步提交，或原子标记缓存待重建，不能发布明细与缓存不一致的结果。
- 标题变化不修改用量事实；项目变化重算该 thread 涉及日期的新旧项目缓存。
- 结构迁移采用明确编号、按顺序执行的 GRDB migration。已发布迁移不就地修改。
- 结构迁移、解析修复、金额重算、统计重建分开执行，避免每次升级全量扫描。
- 不在 usage 每行增加 parser_version；内部维护已完成的数据修复编号和必要进度。
- 迁移前不自动备份数据库，不复制主库或 WAL。保留跨进程写锁、事务迁移、失败回滚及未来 schema 拒绝；失败不得删除或重建用户数据库。旧版已生成的备份保留，不自动删除。
- 设置显示主库及 WAL／共享内存文件长度、迁移备份总数与总大小、最近 20 份备份的元数据和 Finder 定位。元数据后台读取，不扫描历史请求或触发 checkpoint。
- 旧版程序遇到不支持的新 schema 停止写入并明确提示。长时间重建支持断点及崩溃恢复。
- 金额重算的批次结果与内部断点同事务提交，恢复前核对事实、价格、范围和断点版本；依据变化时重新核对，完成后清除进度。断点保存在内部元数据，不增加业务价格版本或请求字段；统计重建的中间结果也必须在完整发布前保持不可见。实现状态见 [维护任务恢复](maintenance-recovery.md)。
- 对 `(thread_id, occurred_at)`、`(account_id, occurred_at)`、`(model, occurred_at)`、价格模型日期和去重键建立适当索引；按实际查询计划调整，不提前堆叠索引。

## 7. CLI 功能范围

以下命令为初版建议，不要求独立维护另一套逻辑。

| 命令 | 能力 |
| --- | --- |
| `tokentick sync` | 增量扫描、价格及 API 同步，报告各来源结果 |
| `tokentick usage` | 按日期、任务、项目、模型查询用量及金额，支持 JSON |
| `tokentick limits` | 查询历史周额度重置前用量百分比 |
| `tokentick current-limits` | 显式联网读取全部当前额度快照 |
| `tokentick status` | 数据库、扫描、缺失价格和同步状态 |
| `tokentick rebuild` | 显式重建统计或重算金额，区分是否需要重新解析 |

查询默认不触发网络同步。结构化结果保留 NULL、金额单位和统计时区，不能把未知输出成 0。App 与 CLI 同一查询条件得到相同结果。

## 8. SwiftUI 视觉与客户端约束

采用 SwiftUI 原生控件和布局，视觉方向为 shadcn Luma，参考 Shuttle 的原生 macOS 界面。Luma 提供圆润几何、柔和层级和宽松间距的方向，不引入 React、Tailwind 或 WebView 来实现界面。[Luma 官方说明](https://ui.shadcn.com/docs/changelog/2026-03-luma)

本次参考了 Shuttle 本地源码的 `OnboardingView.swift`、`ShareAuthorizationView.swift`；参考范围是源码可确认的界面组织与交互，不是本次运行截图验收。

现阶段只要求能展示真实数据以核验统计；精细视觉、完整键盘和 VoiceOver 验收不作为本阶段完成门槛。

具体约束：

- 中性色表面、轻边框、克制阴影，柔和圆角，避免大面积玻璃材质和重装饰。
- 使用系统字体和 SF Symbols，金额及 token 数使用等宽数字。所有界面 token 用量按十进制单位 K／M／B／T 转换，最多两位小数，去尾零，舍入进位时升级单位；悬停查看精确整数。数据库及 CLI JSON 始终保留原始 Int64，不把显示值参与金额计算。
- 参考 Shuttle 的分组表面、主次文字、轻量按钮，以及 hover／pressed／disabled 状态。
- 由少量 Swift 样式值统一颜色、圆角和间距，不先建设通用跨平台组件库。
- 保留 macOS 原生键盘操作、焦点、文本选择和辅助功能语义，适配深浅色。
- 数据密集区域允许紧凑行距；Luma 风格不应导致不必要的留白或影响对比阅读。
- 客户端采用原生侧栏、统计内容区和按需展开的详情检查器；总览、每日用量、任务、项目为主要入口，额度周期和数据状态为辅助入口。
- 菜单栏始终只展示单一模板图标，点击后显示摘要与打开主窗口的入口，不把 token 或金额拼在系统菜单栏上。
- 沿用已定稿的「用量环 · 分格」图标，浅色暖白琥珀、深色石墨薄荷，详见 [品牌决策](brand/decisions.md)。不重新设计图标。
- 默认保持系统原生窗口、侧栏和工具栏行为；内容表面沿用 Luma 的柔和层级，不强制全窗口 Liquid Glass。
- 标准 Settings scene 承载偏好设置，不将设置混为一张统计页面。
- 工程骨架只展示真实空状态，不用模拟 token、假价格、假同步进度或不可用按钮冒充已实现功能。
- [客户端 UI 方案](client-ui.md) 定义首版信息结构和交互，精确视觉值允许在实际数据接入后迭代。

## 9. 验收标准

| 场景 | 必须达到的结果 |
| --- | --- |
| 同一日志重复扫描、App/CLI 先后扫描 | 用量和金额不增加 |
| 活动目录与归档目录之间移动 | rollout 身份、进度及历史统计保持一致 |
| 普通文件压缩为 `.jsonl.zst` | 不丢失、不重复，内容可继续核对 |
| 同一 thread 的多个 revert rollout | 分别跟踪扫描进度，历史请求不重复计费 |
| fork 复制历史与子任务历史 | 只计算实际新增消耗，不重复归属父历史 |
| 新旧 token 事件同时存在 | 不重复计算请求级与累计事件 |
| 半行追加、截断、替换、扫描中崩溃 | 游标不越过未提交数据，恢复后结果一致 |
| 普通／Fast／长上下文／组合模式 | 命中正确费率，覆盖阈值前、阈值上和阈值后 |
| 缺价格、缺模型、缺 Fast | 缺价格或模型保留 NULL；缺 Fast 补查额外日志，仍缺则按普通价格，保留观测未知和计价依据 |
| 每日价格未变／变化／同步失败 | 不增记录／新增日期版本／保留旧数据 |
| 全局与账号筛选 | 全局保留未知账号本地用量，账号筛选只包含匹配值；未归属任务 API 用量不混入汇总 |
| token 显示 | K／M／B／T 转换，零与未知区分，精确整数不丢失 |
| 日桶跨时区、周期跨日期、提前 reset | 不猜测精确请求时点或历史最终百分比 |
| 项目改名 | 按最新映射重建相关项目统计 |
| 重建缓存与直接聚合 | 结果一致 |
| 数据库升级及升级失败 | 保留历史事实，失败事务回滚，不生成自动备份，不静默重置数据库 |
| App 与 CLI | 复用同一计算结果，跨进程同时使用不损坏数据 |
| 大量日志 | 内存随缓冲和批次受控，完整扫描不把全部历史加载到内存 |

性能验收记录同一机器、同一日志集下的首次扫描时间、无变化扫描时间、增量扫描时间、峰值内存与常用查询延迟。先测基线再设具体数值目标，不承诺未测量的 MB 或毫秒指标。

## 10. 实施顺序与待核实项

按 [实现计划](implementation-plan.md) 的 P0–P6 推进：先工程与数据契约，再本地采集、计价、API 对账、客户端绑定和发布验证。

1. 建立脱敏日志 fixtures：普通、fork、revert、压缩、新旧用量事件、缺模型、Fast 和长上下文；核对实际 API 日期及 token 口径。
2. 实现共享数据库、rollout 身份识别、增量采集和去重，用 CLI 验证明细。
3. 实现价格历史、四种模式计价和缺失处理，验证金额分项及重算。
4. 实现独立 API 日桶、历史周额度／实时额度及统计缓存。
5. 完成迁移、并发和大数据量验证，再实现首版 SwiftUI 界面。

当前明确的待核实事项：

- models.dev 已成功读取并验证 48 个 OpenAI 模型条目；未来 schema／规则变化继续按缺失处理，不能沿用未验证乘数。
- 本机 Codex 两个统计接口已可用；仍需验证日桶时区、token 口径和历史覆盖保证。
- 各代本地日志是否足以恢复请求级 Fast 状态、账号归属及缓存计价语义。
- 多个 limit bucket 的用量归属依据，不能按模型名称猜测。
- 最低系统版本已确定为 macOS 26.0；GRDB 和 Zstandard 的本机构建已验证，按用户确认在当前 macOS 27 设备验收，不要求另备 macOS 26 设备。

以上事项影响精确程度的部分保持未知，不能在界面或 CLI 中包装成完整统计。它们不阻止本地采集和数据层先落地。
