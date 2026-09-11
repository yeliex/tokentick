# TokenTick 需求与技术方案

日期：2026-09-11

状态：以本地数据正确性为首要验收，当前范围包含内置默认价格、取消迁移备份、额外日志 Fast 证据及普通模式兜底。当前目标及完成门槛见 [执行目标](goal.md)，逐项证据见 [验收状态](acceptance-status.md)。产品名 TokenTick，仓库和 CLI 为 `tokentick`，默认分支为 `master`。

第一版仅支持 **macOS 26.0+、Apple Silicon（arm64）**，不支持 Intel，不保留 Intel 兼容代码。详细实施顺序见 [实现计划](implementation-plan.md)，客户端布局与交互见 [客户端 UI 方案](client-ui.md)。工程骨架不代表采集、数据库或计价功能已实现。

## 1. 定位与边界

为 macOS 上的 Codex 提供可追溯的 token 用量和美元金额统计。数据先行：先保证采集、归属、计价、持久化和重算正确，再基于数据库扩展视图。

- 统计维度：每个任务（thread）、每天、每个项目、每个模型；周额度单独记录重置前观测百分比。
- 本地日志作为请求用量的主要来源；服务端每日 token 总量只作内存参考，可比范围内显示未知模型差额，不入本地事实统计；额度百分比单独采集。
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

2026-09-11 按用户决定：来源未提供组合价格时，采用普通 tier 的各分项长上下文倍率，推导 Fast 的对应长上下文价格。此为本产品的估算规则，不再以模型白名单限制推导，也不表示该组合已由上游明确公布或保证可用。明确公布的组合价格优先；推导方法和来源写入 `source_json`，详见 4.3。不能用其他 provider 的同名模型价格替代 OpenAI 价格。

官网当前提供 `api.json`（provider 数据）、`models.json`（跨 provider 模型元数据）和 `catalog.json`（合并目录）。价格同步继续读取 `api.json` 的 `openai.models`，使用最新 `cost.tiers[].tier.type/size` 和 `experimental.modes` 格式；不为取得相同价格额外下载合并目录，不依赖 npm SDK。`cost.tiers` 是上下文阶梯，与本库的服务 tier 不是同一维度。模式只有存在明确计价和服务档位含义时才映射为价格行，不能把无 cost 的 reasoning 模式自动当作收费 tier。[官网 API 说明](https://models.dev/#api)、[当前 schema](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts)。

来源：[OpenAI Astra 条目](https://github.com/anomalyco/models.dev/blob/dev/providers/openai/models/gpt-6-astra.toml)、[价格 schema](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts)、[兼容字段生成逻辑](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/generate.ts)、[API 构建入口](https://github.com/anomalyco/models.dev/blob/dev/packages/web/script/build.ts)、[官方 Astra 定价](https://developers.openai.com/api/docs/models/gpt-6-astra)、[官方 Fast 价格表](https://developers.openai.com/api/docs/pricing)、[缓存计费公式](https://developers.openai.com/api/docs/guides/prompt-caching#monitor-cache-performance)。

## 4. 数据结构

以下逻辑结构已于 2026-09-11 实现，另有内部迁移、同步元数据和恢复暂存表。DDL 见 `StoreSchema.swift`；本轮验证见 [优化验收](optimization-validation-20260911.md)。

### 4.1 `threads`：最新任务映射

| 字段 | 含义 |
| --- | --- |
| `thread_id` | 主键，Codex 任务 ID |
| `title` | 最新标题，可空 |
| `project_name` | 最新项目名，可空 |

只作 Codex thread 元数据缓存。不新增 `project_key`、项目历史、`parent_thread_id`、`updated_at`。`cwd` 可用于解析和识别项目，不作为必须持久化的统计字段。

项目名变化后，历史用量按最新映射重新归类。同名项目合并，未知项目用 NULL，不能伪造名称。父子及 fork 标记在解析需要时保留到来源证据中，不要求产品建任务关系图。

项目命名优先使用 Codex 最新项目名；名称缺失或空白时，使用项目根目录文件夹名，根目录提示优先于任务 cwd，避免把 worktree 临时目录或源码子目录当成项目。没有明确项目但仍有工作目录时以该目录名兜底；多个同深度项目存在歧义或没有可用目录时保留未知。Remote 日志中的 Windows 盘符／UNC 路径按原始分隔符提取文件夹名，不通过本机 URL 解析为相对路径，不与本机项目根目录误匹配。

Codex 明确标记为 projectless 的任务，`threads.project_name` 保存为 `Chat`，中文界面显示“无项目聊天”，即使有工作目录也不再推断项目。项目统计仍按名称归组，不引入新的 project ID 或项目历史表。

任务从项目 A 切到 B、移到 Chat、从 Chat 重新关联项目时，直接更新同一 `threads` 缓存记录的 `project_name`。全部历史 usage 通过 thread ID 使用最新归属；变化在同一事务内使统计缓存失效，重建后旧项目不再计入该任务的用量。保留 usage 原始 token、金额、时间和证据，不复制请求或逐条改写项目字段。

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

### 4.3 `prices`：按模型、日期和服务 tier 保存价格变化

联合主键为 `(model, date, tier)`，三列非空。日期固定为 UTC 采集日；tier 使用文本，首批 `standard`、`fast`，后续有明确价格的服务档位增加记录，不增加一组列。OpenAI `default` 映射 standard，`priority` 映射 fast；保留原始值作为证据。

| 字段组 | 内容 |
| --- | --- |
| 身份 | `model`、`date`、`tier` |
| 该 tier 的基础价格 | `input_price`、`output_price`、`cache_read_price`、`cache_write_price` |
| 该 tier 的长上下文价格 | `long_input_price`、`long_output_price`、`long_cache_read_price`、`long_cache_write_price` |
| 阈值 | `long_context_threshold`；按已核实的 OpenAI 规则，输入严格大于阈值才触发，费率用于整个请求 |
| 来源 | `source_json`：原始价格、全部上下文阶梯、模式信息、直接或推导来源及推导输入 |

Fast 单独一行；其 `long_*` 就是 Fast＋长上下文费率。不再设置 `fast_*` 或 `fast_long_*` 列，不增加 price_id、currency、pricing_version、pricing_status 或额外生效时间。单价为美元／百万 tokens，以十进制字符串保存。

首版每个 tier 支持一个长上下文阈值，全部上游阶梯保留在证据中。出现多个有效阈值时报告当前结构不能完整表达，不能静默挑选一个；待真实需求出现再迁移为多阶梯结构。

组合价格逐分项计算：`fast_long_x = fast_x × standard_long_x ÷ standard_x`，x 分别为输入、输出、缓存读取、缓存写入。不能把输入倍率用于输出，也不能把 Fast 固定为 2 倍。计算使用同次同步的普通和 Fast 价格，继承对应上下文阈值；明确的组合费率优先于推导值。分母为零或任一所需价格缺失时，该推导分项留空，不能用别的分项倍率填充。零 token 分项的金额仍为零。没有长上下文阶梯的模型继续用基础价格，不因为不存在 long_* 就将普通请求标为未定价。

例如普通输入／输出为 5／30，长上下文为 10／45，Fast 为 12.5／75，则推导 Fast 长上下文为 25／112.5；倍率分别是 2 和 1.5。该例说明估算算法，不把推导值标为来源直接公布的报价。`source_json` 记录按分项推导的事实、输入价格及来源日期，无需新增业务版本列。

每日成功同步一次。按 `(model, tier)` 与最近记录比较，仅费率、阈值或实际计价依据变化时写当天记录；普通长上下文价格变化也必须重新推导并比较 Fast 行。一次同步的相关价格在同一事务写入，失败不写零价、不清空已有历史。当天成功后不重复采集，不定义日内价格版本。

计价先按模型和 tier 筛选，再取 `date <= 请求 UTC 日期` 的最近记录。请求早于该 tier 首份快照时使用首份快照；日期仍是采集日，不冒充历史生效日。代码内置 `Core/Pricing/openai-default-prices.json` 也使用相同 tier 行结构，补齐旧模型及离线价格。数据库中对应模型／tier 没有可用价格时使用内置配置；已知 Fast 不能因缺 Fast 价而改用普通价。缺 Fast 证据才按 standard 兜底，并保留依据。

新增价格、推导规则或内置 JSON 变化时可恢复地重算受影响用量与缓存；普通增量扫描不全量重算。此次只是目标结构修订，现有宽表、默认 JSON 和计价代码的迁移纳入后续实施。

### 4.4 `turn_usage` 与 `usage`：turn 所有权与逐条用量

**用量保存粒度是每条有效消耗，fork 去重单位是 turn。** `turn_usage` 维护可确认 turn 的最早来源及轮次时间；`usage` 每行保存一次有效用量增量，不再按 turn／model／日期聚合后落库。没有真实 response ID 的旧记录仍逐条保存，但不能宣称每条一定对应一个独立网络请求。完整去重规则见 [逐条用量与 tier 价格方案](usage-and-tier-pricing-plan.md)。

同一 turn 跨任务出现时，保留来源创建时间最早的原始任务，跳过后续任务的整轮副本。时间相同保留已选所有者；没有创建时间时不能用改写后的事件日期证明其更早。更早原始来源晚到时，在事务内替换该 turn 的用量及归属并使缓存失效；原始来源追加继续采集。无需查询祖先链，不用 response ID 决定 fork 所有权。

| 字段组 | 内容 |
| --- | --- |
| 行身份 | 内部 `id`；不设计业务 `dedup_key` |
| 归属 | `account_id`、`thread_id`、`turn_id`，历史不可得时为空；内部关联所有权记录 |
| 响应身份 | 可空 `response_id`，仅保存源系统真实 ID；不由 turn＋序号拼造 |
| 来源定位 | 非空 `rollout_id`、`source_line`；可空 `source_ordinal` 为原日志事件序号，不是轮内请求序号 |
| 时间 | `occurred_at`、可得的 turn 开始时间；UTC 日期 `usage_date`，同时用于价格匹配 |
| 时间分组 | `hour`：UTC 小时，INTEGER，0–23；`minute`：UTC 分钟，INTEGER，0–59；均从 `occurred_at` 派生 |
| 模型和模式 | 可空 `model`、`tier`、`is_long_context`；tier 替代 is_fast，不同时保留两个业务模式字段 |
| 用量 | 单条增量的输入、输出、缓存读取／写入、推理和总 tokens；保留需要的累计基线证据 |
| 采用的单价 | `input_price`、`output_price`、`cache_read_price`、`cache_write_price`，按 tier 与上下文档选择 |
| 金额 | `input_amount`、`output_amount`、`cache_read_amount`、`cache_write_amount`、`amount` |
| 证据 | `source`、`evidence_json`，保存所有对应报告的来源定位、模型／模式与计价依据，不复制正文 |

`usage_date`、`hour`、`minute` 均按同一 `occurred_at` 的 UTC 时间派生，在用量写入或更正时间的同一事务保存。hour／minute 是小时和分钟分量，不是时间戳，也不是每日累计分钟数。未知具体时间时，两列为 NULL，不补成 0；只有日期的证据仍可参加日统计，不进入确定小时／分钟桶。对非空值设置范围 CHECK。

UTC 小时聚合键为 `(usage_date, hour)`，分钟聚合键为 `(usage_date, hour, minute)`；不能单独按 hour 或 minute 分组后称为连续时间序列。明细新增一个 `(usage_date, hour, minute)` 复合索引支持日期范围及时间桶查询，不为 hour／minute 单独建索引。统计时区不同于 UTC 时，从原始 occurred_at 转换后生成目标桶，不直接套用 UTC 分量；连续时间桶用实际桶起始时刻区分夏令时重复小时。切换时区只影响查询和缓存，不改写明细时间分量。

小时／分钟统计表示用量事件归属时间下的 tokens 和金额，不表示请求运行过程中每分钟实际消耗。只有汇总增量或缺少开始／结束证据时不均摊到多个分钟。新增时间列用于后续聚合，本次不新增小时／分钟页面或独立全量缓存。

旧日志实测存在没有 turnId 的记录，不能强制非空或补造。source_ordinal 有则原样保存，缺失仍可用 rollout＋行号定位。上述物理定位用于重扫幂等，不能作为跨任务同一消耗的证明。没有 turnId 的记录保留未知归属边界，不凭相同 tokens 合并。

先确定 turn 所有者，再在该来源内消除重复累计快照和新旧格式的重复报告。有真实 response ID 时用于轮内匹配；没有 ID 时按已验证的事件序列和累计流处理。每个确定匹配的新旧报告只形成一条统计行，保留两份来源定位；不能只根据 token 数相同或固定时间差判断。切换查询时区基于逐条时间重建缓存；长上下文按单条输入判断，不能用整个 turn 的输入总和。

输入与输出保留源语义，缓存／推理是分项，不能把所有列相加。累计差分无法确认是单次请求时保留粒度证据；不能拿多次调用合计输入判断长上下文。tier 未知时保持 NULL，实际按 standard 计价并记录 default_standard。长上下文标记指计价档位，不指模型最大上下文能力。

Fast 判定优先使用 rollout 明确值；缺失时只读当前 CODEX_HOME 下 `logs_*.sqlite`，从 websocket 的顶层 `response.create.service_tier` 或 `TurnInput`／`UserInput` 提交补齐相同 thread ID + turn ID 的 Fast 证据。仅配置更新的 Submission ID 不当作轮次 ID；正文嵌套字段不作依据。仍无证据则按普通费率计算，不因缺 Fast 单独标为未定价。统计证据区分 rollout、trace 与 default_standard，保留 trace 文件名、行 ID 和观测时间，不复制请求正文。额外日志按文件身份和行 ID 增量读取，证据及游标同事务保存；后到的 Fast 证据重新计算对应轮次，重复读取不重复计量。监听数据库及 WAL 变化，忽略仅 SHM 变化。

模型无法取得的记录保持 `model = NULL`，模型维度统一显示为“其他”，继续参加 token 汇总；不是必须补齐模型的待办，也不凭模型缺失推断设备来源。已有任务映射保留，无法绑定任务的 API 数据允许 `thread_id = NULL`。

无价格的非零用量，对应单价及金额为 NULL。零用量对应金额为零；有任一非零分项无法计价时，总金额为 NULL，仍保留可算的分项金额。不设置独立 pricing_status。

用量记录保存当次采用的单价，支持直接解释金额；价格表保存日期规则。明确重算时同时更新用量单价、金额及受影响统计。金额统一采用整数纳美元（1 USD = 10^9 单位），用十进制计算后按约定的银行家舍入写入；单价保存十进制字符串，禁止 Double 累加金额。

### 4.5 API 每日 tokens：内存参考数据

`account/usage/read` 实测每日桶只有 `startDate`、`tokens`，没有每日模型或输入／输出分项，无法据此计算金额。按后续用户决定，账号摘要、日桶及其观测时间只保留内存，不建立或继续维护 `api_daily_usage` 历史事实；任务级查询、模型分组持久化和 API 金额不再是当前完成条件。此调整不删除需要持久化的历史周额度证据。

同账号、同日桶及 token 口径可比时，以 API 总量减去本地已覆盖 tokens，非负差额单独显示为“其他／未知模型”的参考 tokens，不入 usage、不计金额、不重复加进本地事实或统计缓存。本地已覆盖量包含未知模型与 remote 同步落盘记录。负差额展示为零并保留差异，不能减掉本地已确认用量。

API 不直接携带可确认账号时，利用观测前后账号一致性核对；期间切换账号则不归属本次数据。历史本地账号未知或日桶语义未确认时，不能把差额称为精确的其他设备用量；可保留参考估计及其范围限制，不混入明确账号统计。API 日期原样保留，不能擅自转成机器本地日。

实时 API 状态保留结果时间、账号及错误，旧观测不能覆盖较新状态；本地同步不覆盖 API 状态。接口现状和旧实现记录见 [API 对账核验](api-reconciliation.md)，其中持久日桶的描述为旧实现，当前代码已采用以上内存方案。

### 4.6 `weekly_limit_observations`：七天限额证据

固定筛选主额度桶 `codex` 且时长 10,080 分钟的窗口，不区分 primary／secondary，不纳入五小时或额外模型桶。原始事实包含 `id`、`scope_key`、可空 `account_id`、`limit_id`、`observed_at`、`resets_at`、`used_percent`、`source_json`、可空 `turn_id`、`exclusion_reason` 和 `collected_at`；来源保留文件名及行号，不用当前账号回填历史。

按稳定截止归并窗口：正用量的截止采用固定锚点 60 秒容差，选取观测最多的秒值作为代表；附近 30 秒内的零值可补充首次观测，单独滚动的零值不形成窗口。起算时间为稳定截止减七天，明确标为推算；额度恢复后长时间空闲时，归零时间与起算时间不同。最后百分比、峰值、首次观测、首次正用量及最后观测分别保存，同刻末值冲突时留空，不靠百分比下降拆出多个历史条目。

`weekly_limit_cycles` 是按查询范围保存的内部缓存。全局归并全部窗口证据；指定账号只从明确属于该账号的观测计算，未知账号独立计算，不把全局结果补归属。日期筛选和分页按推算起算时间，包含当前已固定窗口。账号明确且有前后证据时另存额度归零观测，不冒充实际手动重置时间。最终百分比、周期 tokens／美元缺少证据时保持未知。

v9 只重建窗口缓存并增加范围索引，不备份或清空原始观测、token 与金额。SQLite 汇总数值证据后只向 Swift 返回统计点；同一查询范围原子发布缓存，失败回滚后重试。

**实时额度**仍用内存 `CurrentLimitSnapshot` 保存所有可得额度类型及实际观测时间，完整快照不落库。`current-limits` 显式联网查询，`limits` 查询七天窗口和可重建缓存。详细字段、规则与限制见 [七天窗口方案](weekly-window-plan.md)，真实结果见 [实现验收](weekly-start-validation.md)。

历史窗口 tokens 和金额根据已观测窗口查询本地用量；跨窗口 turn 按 turn 开始时间归属，使用半开区间，属于展示近似。稳定历史结果可写入统计缓存，不能从额度百分比推算 tokens 或金额，也不能将整个任务的多周用量按任务创建时间归入一周。

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

实现约定：账号键使用 `all`／`unknown`／`value:<ID>`；维度值使用 `all`／`unknown`／`value:<实际值>`，实际名称与哨兵不会冲突。未归属 tokens 指缺少 thread 的用量。另保存已知总金额 `known_amount` 和未完整计价记录数 `unpriced_records`；非零分项缺失时不能因其他零分项而生成零总金额。API 日桶差额只在内存展示，不写入明细或汇总。

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
- fork 的复制历史优先按 turn 所有权排除，revert 的重复回放依据原事件身份和历史边界去重。累计值减少不能直接产生负数或默认为新请求。
- 时间、模型和观测模式无法恢复时保留未知。不能用当前配置给数月前请求补模型或 Fast 状态；缺少 Fast 证据只影响计价选择，按普通模式兜底并记录依据。
- 读取历史 `thread_settings_applied`，核对 thread 所有权和继承边界；在 `task_started`／`turn_started` 时绑定该轮设置。持久设置更新不追溯改变正在执行的轮次。后续同轮 `turn_context` 缺少 service tier 字段时保留已绑定证据，显式 NULL 则清除；不同轮次不能沿用。
- 前置压缩可能早于本轮 `turn_context`，且模型切换时可能使用上一模型；存在多个候选时保留未知模型及候选证据，不能直接采用新设置。模型、模式证据各自保存来源 rollout、文件名和行号。
- 同一原始轮次的重复事件通过持久去重状态过滤；同一事件的 token 或已知模型／模式冲突时回滚本批及游标。解析器升级需核对已保存的逐条证据能否复用，缺失的源信息不能凭空恢复。

### 5.2 身份与证据

跨任务先按 turn 选择最早来源并排除整轮副本；源系统真实响应 ID 用于该来源的轮内去重。文件名、行号、token 数组合不构成可靠的跨文件请求身份；没有稳定 ID 的旧记录采用经验证的来源边界和事件序列规则，不引入业务 dedup_key。

不为“完整保留数据”复制整个 Codex 日志。保存足以支持重新计价、归属核对和累计差分的统计字段；源日志以后删除时，已经保存的数据仍能重建统计，未曾采集的信息不能承诺恢复。

### 5.3 时间与网络同步

事件保存 UTC 时间戳，日统计使用明确的 IANA 时区，默认采用首次初始化时的系统时区并记录。切换统计时区只重建日缓存，不改变事件时间。价格日期始终使用 UTC，API 日期语义未验证前仅展示参考差额，不声称是精确跨设备用量。

日期筛选使用所选统计时区，首尾日期均包含；分页顺序稳定。只有 UTC 日日期而无精确发生时间的已入库记录，在其他时区不能精确换算，归入未知日期。带日期范围的查询不把这些记录硬塞进范围，另返回该账号范围下的 `unknownDateTokens`，不声称它们属于所选日期。

价格同步每日一次，失败可有限重试；额度和日用量按应用运行状态节制刷新。App 默认启用自动同步，可在设置中关闭：启动执行全来源同步，文件事件合并 2 秒后触发本地核对，事件触发的本地扫描至少间隔 10 秒；监听正常时每 30 分钟兜底核对，监听不可用时每分钟核对，远端每五分钟单独刷新（不顺带扫描日志），价格仍按每日成功一次去重。正在同步时合并触发，完成后处理待办，不并发创建多个扫描者。取消后至少 60 秒不自动重启；休眠期间暂停计时，唤醒后重新监听并补扫，不重放所有错过的周期。通知失效时保留定时核对，目录恢复后重试监听。应用关闭不承诺持续采集额度历史；首版不额外建设常驻 daemon。CLI 可显式执行同步。

## 6. 数据一致性、迁移与维护

- SQLite 使用 WAL 和事务；App 与 CLI 的写入／扫描／迁移使用共享的跨进程协调，不能只靠进程内 actor。
- 每批解析结果、扫描进度、受影响日统计同步提交，或原子标记缓存待重建，不能发布明细与缓存不一致的结果。
- 标题变化不修改用量事实；项目变化重算该 thread 涉及日期的新旧项目缓存。
- 结构迁移采用明确编号、按顺序执行的 GRDB migration。已发布迁移不就地修改。
- 结构迁移、解析修复、金额重算、统计重建分开执行，避免每次升级全量扫描。
- 不在 usage 每行增加 parser_version；内部维护已完成的数据修复编号和必要进度。
- 尚未上线的 v6 及本轮 v11 切换按用户明确要求直接清空旧用量、扫描游标、统计缓存和维护断点，然后重扫原始日志；不修复旧请求记录，不保留无法重扫的旧统计。价格、任务缓存和周额度观测保留；v12 删除旧 API 日桶和账号摘要缓存。该一次性重置不代表后续正式版本允许任意清库。
- 迁移前不自动备份数据库，不复制主库或 WAL。保留跨进程写锁、事务迁移、失败回滚及未来 schema 拒绝；失败不得删除或重建用户数据库。旧版已生成的备份保留，不自动删除。
- 设置显示主库及 WAL／共享内存文件长度、迁移备份总数与总大小、最近 20 份备份的元数据和 Finder 定位。元数据后台读取，不扫描历史请求或触发 checkpoint。
- 旧版程序遇到不支持的新 schema 停止写入并明确提示。长时间重建支持断点及崩溃恢复。
- 金额重算的批次结果与内部断点同事务提交，恢复前核对事实、价格、范围和断点版本；依据变化时重新核对，完成后清除进度。断点保存在内部元数据，不增加业务价格版本或请求字段；统计重建的中间结果也必须在完整发布前保持不可见。实现状态见 [维护任务恢复](maintenance-recovery.md)。
- 对 `(thread_id, occurred_at)`、`(account_id, occurred_at)`、`(model, occurred_at)`、价格模型／tier／日期、turn 所有权和源事件定位建立适当索引；按实际查询计划调整，不提前堆叠索引。

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
4. 将 API 日桶改为内存参考差额；保留历史周额度／实时额度职责，完善窗口 tokens 与金额展示缓存。
5. 完成迁移、并发和大数据量验证，再实现首版 SwiftUI 界面。

当前明确的待核实事项：

- models.dev 已成功读取并验证 48 个 OpenAI 模型条目；未来 schema／规则变化继续按缺失处理，不能沿用未验证乘数。
- 本机 Codex 两个统计接口已可用；仍需验证日桶时区、token 口径和历史覆盖保证。
- 各代本地日志是否足以恢复请求级 Fast 状态、账号归属及缓存计价语义。
- 多个 limit bucket 的用量归属依据，不能按模型名称猜测。
- 最低系统版本已确定为 macOS 26.0；GRDB 和 Zstandard 的本机构建已验证，按用户确认在当前 macOS 27 设备验收，不要求另备 macOS 26 设备。

以上事项影响精确程度的部分保持未知，不能在界面或 CLI 中包装成完整统计。它们不阻止本地采集和数据层先落地。
