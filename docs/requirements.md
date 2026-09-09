# TokenTick 需求与技术方案

日期：2026-09-09

状态：需求基线、macOS 工程与本地采集实现中。产品名 TokenTick，仓库和 CLI 为 `tokentick`，默认分支为 `master`。

第一版最低系统版本确定为 **macOS 26.0**。详细实施顺序见 [实现计划](implementation-plan.md)，客户端布局与交互见 [客户端 UI 方案](client-ui.md)。工程骨架不代表采集、数据库或计价功能已实现。

## 1. 定位与边界

为 macOS 上的 Codex 提供可追溯的 token 用量和美元金额统计。数据先行：先保证采集、归属、计价、持久化和重算正确，再基于数据库扩展视图。

- 统计维度：每个任务（thread）、每天、每个项目、每个模型，以及已观测的 limit 周期。
- 本地日志作为请求用量的主要来源；服务端每日 token 总量用于补充未归属用量；额度百分比单独采集。
- 金额是按模型公开价格换算的 API 等值金额，不等同于 ChatGPT 订阅实际账单。
- 完整保存统计相关字段和必要的统计来源证据，不保存对话正文、工具输出或凭据。
- 第一版只支持 macOS 26 及更新版本和 Codex，不建设多 provider 框架、跨平台 CLI 或自有云同步服务。
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

业务主体采用七张表，另有数据库内部迁移和同步元数据。以下为逻辑字段定义；正式 DDL 应在日志样本与接口契约测试完成后确定。

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

扫描状态与本批用量在同一事务提交。半行写入保留到下次读取，不能提前推进游标。普通文件可按字节定位；压缩文件通过流式解压跳过已提交数据，不能把解压后偏移直接用于压缩文件 seek。

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

请求计价选择 `date <= 请求 UTC 日期` 的最近一条记录，再按模式与阈值选费率。首次采集以前的历史不能自动用今日费率覆盖；如以后导入可靠历史价格，必须走明确的回填与重算流程。

### 4.4 `usage`：用量事实、所用单价和金额

| 字段组 | 内容 |
| --- | --- |
| 行身份 | 内部 `id`、唯一 `dedup_key` |
| 请求归属 | `account_id`、`thread_id`、`turn_id`、`request_id`／`response_id`，不可得时为空 |
| 时间 | `occurred_at`；API 日差额使用 `usage_date`，不伪造请求时间 |
| 模型和模式 | `model`、可空 `is_fast`、可空 `is_long_context` |
| token 明细 | `input_tokens`、`output_tokens`、`cache_read_tokens`、`cache_write_tokens`、`reasoning_tokens`、`total_tokens` |
| 采用的单价 | `input_price`、`output_price`、`cache_read_price`、`cache_write_price` |
| 金额 | `input_amount`、`output_amount`、`cache_read_amount`、`cache_write_amount`、`amount` |
| 证据 | `source`（local／api）、`rollout_id`、`source_line`、`evidence_json` |

`evidence_json` 仅保存统计事件、定位信息、模型／模式依据、必要历史所有权标记，不保存包含正文的整段日志。来源文件位置通过 rollout 扫描记录查询；证据可保留采集时文件名，文件搬迁不改变用量身份。

输入和输出列保留来源对应的总量语义，缓存和推理属于分项；公式中的可计费输入必须按对应日志契约扣除已包含的缓存部分。不能把所有 token 列直接相加。请求级、新旧累计事件都要保留必要证据，但同一实际消耗只形成一份可统计用量。

只保留一个 Fast 标记，不再重复增加 `service_tier` 业务列；原始返回值可保留在统计证据内。长上下文标记表示该请求触发高档计价，不表示模型的最大上下文能力。来源未知时不能默认 false。

无价格的非零用量，对应单价及金额为 NULL。零用量对应金额为零；有任一非零分项无法计价时，总金额为 NULL，仍保留可算的分项金额。不设置独立 pricing_status。

用量记录保存当次采用的单价，支持直接解释金额；价格表保存日期规则。明确重算时同时更新用量单价、金额及受影响统计。金额统一采用整数纳美元（1 USD = 10^9 单位），用十进制计算后按约定的银行家舍入写入；单价保存十进制字符串，禁止 Double 累加金额。

### 4.5 `api_daily_usage`：服务端每日总量缓存

逻辑主键 `(account_id, start_date)`。保存 `start_date`、`tokens`、`fetched_at`；保留接口返回的日期，不擅自转换成机器本地日期。API 摘要统计响应保存在内部同步元数据，避免复制到每天一行。

真实接口 `account/usage/read` 的每日桶提供 `startDate` 和 `tokens`，日桶可能为空，不包含模型、token 分项或金额。接口摘要还可包含累计 tokens 等统计。能力依赖实际 Codex 服务及认证，接入时做能力检查。[App Server 文档](https://learn.chatgpt.com/docs/app-server)

每日差额规则：

1. 先确认账号、日期边界、token 包含关系和覆盖范围可比较；不能因当前登录账号相同就把所有历史日志归到该账号。
2. 服务端日总量减去可比本地日总量，正差额写成一条可更新的 `source=api` 用量，thread、模型、分项和金额为空。
3. API 总量缓存本身不参与相加，只把差额纳入总统计。
4. 后续补扫本地数据后重算并缩减差额；不每次追加新差额。
5. 差额为负不创建负用量，应保留两侧数据并报告口径或同步异常；缺失 API 日桶不等于零。

“未知任务用量”只意味着无法归属，不能宣称全部来自其他设备。不能根据日 tokens 猜测金额或把其均匀拆成小时。

### 4.6 `limit_windows`：额度周期历史及周期统计

逻辑主键 `(account_id, limit_id, window_kind, resets_at)`。

保存 `window_duration_mins`、推算的 `starts_at`、`resets_at`、最后观测的 `used_percent`、`last_observed_at`、相关原始统计响应，以及可归属的 `tokens`、已知分项金额、未定价 tokens 缓存。

`account/rateLimits/read` 返回窗口时长、重置时间和当前百分比，不直接提供周期 tokens、金额或历史最终值。[接口契约](https://learn.chatgpt.com/docs/app-server)

周期 token 与金额从 `[starts_at, resets_at)` 内、能归属该 limit 的用量计算；这是当前采集覆盖下的统计，不保证全账号完整。每日 API 差额无法精确归到非自然日边界的周期。不能通过额度百分比推算 tokens 或金额。

窗口开始时间为结束时间减时长的推定值。提前 reset、窗口变化按新观测记录处理，不伪造旧周期实际结束时间。未观测到周期末尾时，最后一次百分比不能称为最终百分比。primary 与 secondary 可能重叠，同一消耗可出现在各自周期统计中，但不能跨周期类型直接相加。

### 4.7 `statistics`：可重建统计缓存

第一版按日保存全局、任务、项目及模型维度的聚合；时间范围汇总从日缓存求和，细分交叉查询可以直接执行 SQLite 查询，不预计算所有维度组合。

| 字段组 | 内容 |
| --- | --- |
| 缓存键 | `account_id`、`date`、`timezone`、`dimension`、`dimension_value` |
| token 统计 | 总 tokens 及可得的输入／输出／缓存／推理分项 |
| 金额统计 | 已知分项金额、完整计价请求金额 |
| 完整性 | 未定价用量、未归属用量、必要的记录数量 |

全局、任务、项目和模型行是同一事实的不同汇总，不能相加成总量。API 差额作为未归属数据参与正确维度；总 tokens 可能大于已知分项之和。SQL `SUM` 忽略 NULL，不能以求和成功判断金额完整。

SQLite 中 NULL 不自动提供期望的复合唯一性；全局／未知维度使用明确的内部键约定或对应唯一索引，不依赖可空列阻止重复缓存。

## 5. 采集、归属和同步规则

### 5.1 本地采集

- 从配置的 Codex 数据目录发现活动与归档 rollout，包含 JSONL 与 Zstandard 压缩文件。
- 流式逐条解析，限定读取缓冲及入库批次；超长的非统计正文记录可跳过，不整行长期驻留内存。
- 文件通知仅作为增量扫描提示；启动和恢复运行时重新核对目录，弥补漏通知。
- 明确请求级记录、累计 token 快照和上下文 token 数的区别；上下文长度不等于本次计费用量。
- 优先处理有请求／响应 ID 的用量记录，旧格式按经过样本验证的规则回退，不能把新旧事件同时相加。
- fork／revert 的复制历史依据请求身份、源所有权和历史边界去重。累计值减少不能直接产生负数或默认为新请求。
- 时间、模型、模式无法恢复时保留未知。不能用当前配置给数月前请求补模型或 Fast 状态。

### 5.2 身份与证据

请求去重优先使用源系统可用的稳定请求／响应 ID。文件名、行号、token 数组合不构成可靠的跨文件请求身份；没有稳定 ID 的旧记录必须采用经验证的来源边界规则。

不为“完整保留数据”复制整个 Codex 日志。保存足以支持重新计价、归属核对和累计差分的统计字段；源日志以后删除时，已经保存的数据仍能重建统计，未曾采集的信息不能承诺恢复。

### 5.3 时间与网络同步

事件保存 UTC 时间戳，日统计使用明确的 IANA 时区，默认采用首次初始化时的系统时区并记录。切换统计时区只重建日缓存，不改变事件时间。价格日期始终使用 UTC，API 日期语义未验证前不用于跨设备差额。

价格同步每日一次，失败可有限重试；额度和日用量按应用运行状态节制刷新。应用关闭不承诺持续采集额度历史；首版不额外建设常驻 daemon。CLI 可显式执行同步。

## 6. 数据一致性、迁移与维护

- SQLite 使用 WAL 和事务；App 与 CLI 的写入／扫描／迁移使用共享的跨进程协调，不能只靠进程内 actor。
- 每批解析结果、扫描进度、受影响日统计同步提交，或原子标记缓存待重建，不能发布明细与缓存不一致的结果。
- 标题变化不修改用量事实；项目变化重算该 thread 涉及日期的新旧项目缓存。
- 结构迁移采用明确编号、按顺序执行的 GRDB migration。已发布迁移不就地修改。
- 结构迁移、解析修复、金额重算、统计重建分开执行，避免每次升级全量扫描。
- 不在 usage 每行增加 parser_version；内部维护已完成的数据修复编号和必要进度。
- 迁移前用 SQLite 支持的备份方式生成一致快照，不能仅复制处于 WAL 模式的主文件。
- 旧版程序遇到不支持的新 schema 停止写入并明确提示。长时间重建支持断点及崩溃恢复。
- 对 `(thread_id, occurred_at)`、`(account_id, occurred_at)`、`(model, occurred_at)`、价格模型日期和去重键建立适当索引；按实际查询计划调整，不提前堆叠索引。

## 7. CLI 功能范围

以下命令为初版建议，不要求独立维护另一套逻辑。

| 命令 | 能力 |
| --- | --- |
| `tokentick sync` | 增量扫描、价格及 API 同步，报告各来源结果 |
| `tokentick usage` | 按日期、任务、项目、模型查询用量及金额，支持 JSON |
| `tokentick limits` | 查询已观测周期及可归属用量 |
| `tokentick status` | 数据库、扫描、缺失价格和同步状态 |
| `tokentick rebuild` | 显式重建统计或重算金额，区分是否需要重新解析 |

查询默认不触发网络同步。结构化结果保留 NULL、金额单位和统计时区，不能把未知输出成 0。App 与 CLI 同一查询条件得到相同结果。

## 8. SwiftUI 视觉与客户端约束

采用 SwiftUI 原生控件和布局，视觉方向为 shadcn Luma，参考 Shuttle 的原生 macOS 界面。Luma 提供圆润几何、柔和层级和宽松间距的方向，不引入 React、Tailwind 或 WebView 来实现界面。[Luma 官方说明](https://ui.shadcn.com/docs/changelog/2026-03-luma)

本次参考了 Shuttle 本地源码的 `OnboardingView.swift`、`ShareAuthorizationView.swift`；参考范围是源码可确认的界面组织与交互，不是本次运行截图验收。

具体约束：

- 中性色表面、轻边框、克制阴影，柔和圆角，避免大面积玻璃材质和重装饰。
- 使用系统字体和 SF Symbols，金额及 token 数使用等宽数字。
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
| 缺价格、缺模式、缺模型 | 保留 token 和未知状态，不伪造零金额 |
| 每日价格未变／变化／同步失败 | 不增记录／新增日期版本／保留旧数据 |
| API 差额后补本地记录 | 相应差额缩减，合并总量不重复 |
| 日桶跨时区、周期跨日期、提前 reset | 不猜测精确请求时点或历史最终百分比 |
| 项目改名 | 按最新映射重建相关项目统计 |
| 重建缓存与直接聚合 | 结果一致 |
| 数据库升级及升级失败 | 保留历史事实，有可恢复备份，不静默重置数据库 |
| App 与 CLI | 复用同一计算结果，跨进程同时使用不损坏数据 |
| 大量日志 | 内存随缓冲和批次受控，完整扫描不把全部历史加载到内存 |

性能验收记录同一机器、同一日志集下的首次扫描时间、无变化扫描时间、增量扫描时间、峰值内存与常用查询延迟。先测基线再设具体数值目标，不承诺未测量的 MB 或毫秒指标。

## 10. 实施顺序与待核实项

按 [实现计划](implementation-plan.md) 的 P0–P6 推进：先工程与数据契约，再本地采集、计价、API 对账、客户端绑定和发布验证。

1. 建立脱敏日志 fixtures：普通、fork、revert、压缩、新旧用量事件、缺模型、Fast 和长上下文；核对实际 API 日期及 token 口径。
2. 实现共享数据库、rollout 身份识别、增量采集和去重，用 CLI 验证明细。
3. 实现价格历史、四种模式计价和缺失处理，验证金额分项及重算。
4. 实现日 API 对账、额度周期记录与统计缓存。
5. 完成迁移、并发和大数据量验证，再实现首版 SwiftUI 界面。

当前明确的待核实事项：

- 线上 models.dev API 的实际返回及部署版本：本次返回 403，已核对上游字段与构建代码。
- 本机 Codex 服务端接口可用性，以及日桶时区、token 口径、历史覆盖范围。
- 各代本地日志是否足以恢复请求级 Fast 状态、账号归属及缓存计价语义。
- 多个 limit bucket 的用量归属依据，不能按模型名称猜测。
- 最低系统版本已确定为 macOS 26.0；GRDB 和 Zstandard 的本机构建已验证，仍需完成 macOS 26 真机验收。

以上事项影响精确程度的部分保持未知，不能在界面或 CLI 中包装成完整统计。它们不阻止本地采集和数据层先落地。
