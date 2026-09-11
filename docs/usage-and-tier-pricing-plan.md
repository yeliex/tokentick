# 逐条用量与 tier 价格方案

更新：2026-09-11。状态：数据库与采集、计价、API 内存差额及窗口缓存已实现；本文替代旧方案中“turn 是最小保存粒度”和“四组价格前缀”的决定。字段以 [需求文档](requirements.md) 4.3–4.5 为准。

## 保存粒度和 fork 去重

每条有效消耗保存一行 usage，响应 ID 可空；turn 用于所有权和归属。没有真实 response ID 的历史增量仍单独存，但不伪造响应 ID，也不把采集记录数当作精确网络请求数。

1. 按来源任务创建时间扫描，按 turnId 查已有所有者。较晚来源的同 turn 是整轮副本，跳过；原始所有者持续追加时正常计量。
2. 较早来源晚到时，事务内替换该 turn 的事实和所有权，使相关缓存失效。使用源创建证据，不使用 fork 改写后的事件日期、mtime 或文件遍历偶然顺序。无需查询祖先链。
3. 选定所有者后，再处理其轮内记录：真实 response ID、累计快照和已验证的新旧格式对应关系各司其职。
4. 不新增业务 dedup_key。唯一索引用于落实已明确的 turn 所有权及轮内真实响应身份；源记录定位使用普通索引，文件替换后同一行号可能对应新事件；拼接或哈希并不能证明两条事件是同一次消耗。
5. turn_id 和 source_ordinal 不强制非空：真实旧日志缺 turnId；ordinal 是上游事件位置，不是轮内响应序号。源 rollout 和行号必须保存。缺 turnId 时不声称具备完整的跨任务去重能力。

“fork 复制完整已完成 turn”是本项目采用的处理约定。当前证据也包含只有部分日志可见的副本，因此更早原始来源晚到的事务替换仍有必要；不能因为正常扫描通常有序就移除此兜底。

## 用量时间字段

保留 occurred_at 和 usage_date，新增 hour、minute。所有明细时间分量固定 UTC，来源时间始终以 occurred_at 为准。

| 字段 | 类型与含义 |
| --- | --- |
| occurred_at | 原始用量发生／报告时间，保留原有精度 |
| usage_date | UTC 日期 YYYY-MM-DD，用于日期统计及价格匹配 |
| hour | 可空 INTEGER，UTC 小时 0–23 |
| minute | 可空 INTEGER，UTC 分钟 0–59 |

例如 `2026-09-11T03:27:45Z` 保存日期 2026-09-11、hour=3、minute=27；Asia/Shanghai 查询显示 11:27，明细仍保持 UTC。hour／minute 与日期在入库或时间更正时由同一 timestamp 生成，同事务写入；设置范围约束。具体时间缺失时不伪造午夜，两列留空，已知日期仍可参与日汇总。

UTC 按小时使用 date＋hour，按分钟使用 date＋hour＋minute；增加一个 `(usage_date, hour, minute)` 复合索引。其他时区基于 occurred_at 生成桶，连续序列按实际桶起始时刻区分夏令时重复小时；不更改已有 UTC 分量。不得将某条报告的用量均摊到其前后分钟，也不拿 turn 开始时间替代一般小时／分钟统计时间。额度窗口的 turn 开始时间近似归属是独立规则。

本次确定存储及查询契约，后续小时／分钟视图按需迭代，不预先增加页面或全维度分钟缓存。

## ordinal 不同的新旧格式重复

AIChat 样本 `rollout-2026-08-27T11-18-15-01a04139-b2cc-76a3-9906-0df67875f49b.jsonl` 的 turn `01a0652a-d388-7251-8f78-2208dd7c0964`：

| 报告 | 行号 | ordinal | 本次 tokens | 该格式累计 tokens |
| --- | ---: | ---: | ---: | ---: |
| token_usage_record | 17829 | 17828 | 172044 | 172044 |
| token_count | 17831 | 17830 | 172044 | 419766598 |

两个 ordinal 标识两条报告，不能据此算成两次消耗；两种格式的累计基线也不同。已识别的模式是同一原始 turn 内，新格式之后的对应旧报告具有一致的完整用量分项，按解析器的连续事件状态绑定为同一消耗。对应关系确认后只计一次，当前逐条结构保留两份报告的定位证据。

当前实现对这类模式已有处理，2026-09-11 重跑 `swift test --filter TurnUsageTests`，6 项通过。其中 `mixedFormatsWithDifferentCumulativeBaselinesSurviveRestartAndReplay` 覆盖上述用量与不同累计基线、跨批次重启和重扫。真实样本验收见 [旧结构验证记录](turn-usage-validation.md)。这不意味着“同 turn 且 tokens 相同”可以推广为通用重复判据；多次真实响应可能恰好用量相同。

迁移逐条结构时须保留这些保证，并增加反例：同 turn 两个不同 response ID 的相同 token 用量必须各计一次；不同 ordinal 的已匹配双格式只计一次；新旧顺序反转、只有一种格式、丢失对应事件时不能盲目配对。

## tier 和上下文价格

价格联合主键 `(model, date, tier)`。每行包含该 tier 的基础 input/output/cache_read/cache_write 价格、long_context_threshold 和 long_* 价格。Fast 是独立行；其 long_* 表示 Fast＋长上下文。不再为每个服务档位增加列。

优先取明确组合价格；没有时按用户确定的估算规则逐分项计算：

```text
该 tier 的长上下文分项价格
  = 该 tier 的基础分项价格
  × standard 的长上下文分项价格
  ÷ standard 的基础分项价格
```

分母必须大于零且三项价格齐全；不能推导的分项留空。输入、输出及缓存各自算倍率；不能统一乘 2。source_json 保存推导输入和来源，表示估算而非上游直接报价，不新增价格版本或状态业务列。上游未来直接提供组合费率时优先使用它，并触发受影响金额重算。

## models.dev 接口选择

2026-09-11 核对 [官网 API 说明](https://models.dev/#api)、[schema](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts) 与 [生成器](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/generate.ts)：

- api.json 是 provider 数据；models.json 是跨 provider 元数据；catalog.json 是合并目录。继续从 api.json 的 openai.models 获取 OpenAI 实际价格，不采用首页跨 provider 展示价格。
- 基础价格来自 cost；长上下文来自 cost.tiers 中 type=context 的 tier.size 和对应分项。不要从模型 limit.context 推断计价阈值。
- context_over_200k 为兼容输出；新的作者 schema 禁止维护该旧字段。优先 tiers，只有旧数据存在已核实阈值时才兼容；不能从字段名臆定 200000。
- Fast 来自 experimental.modes.fast.cost，对应 provider.body.service_tier=priority。当前模式 cost 不含上下文 tiers，所以需要上述组合推导。
- cost.tiers 的 tier 是上下文维度，本库 tier 是服务档位。无独立 cost 的 reasoning 模式不自动变成价格行。Swift 直接解析 JSON，无需引入 npm SDK。

## 实施顺序与验收

1. 先迁移价格宽表和内置 JSON 为 tier 行，调整最新 API 解析及分项推导；保留日期历史、默认价和无 Fast 证据时的普通价兜底。
2. 再将 usage 改成逐条事实，turn 表仅负责所有权；保留原始 response ID、可空 turnId／ordinal 和必要证据；新增 UTC hour／minute 及日期复合索引，同步更新采集写入、时间更正和明细返回。旧聚合无法无损拆分，按未上线项目的重扫策略重建，不伪造逐条历史。
3. API 日桶改为内存参考差额；窗口 tokens／金额基于已观测窗口查询本地事实，稳定历史结果可存统计缓存。跨窗口的 turn 接受按 turn 开始时间归属的近似，不将整个长期任务按创建时间归入一周。窗口使用半开区间，避免边界双计。
4. 验收价格快照变更和不变、Fast 独立日期回溯、输出倍率不同、零／缺失分项、明确报价覆盖估算、新格式优先，以及本节列出的去重反例。核对真实 AIChat、直接求和与缓存一致；不将旧结构测试通过称为新结构已验收。

## 本轮改动清单

| 模块 | 明确改动 | 验收重点 |
| --- | --- | --- |
| 数据库与数据类型 | prices 改为 model＋date＋tier；usage 改逐条事实，分开 response_id／turn_id，增加 hour／minute；移除聚合专用字段及业务 dedup_key；turn 保留所有权职责 | 字段语义、可空值、唯一及范围约束；升级事务失败回滚，无自动备份 |
| 本地采集 | 先按 turn 选择最早来源，再消除轮内重复报告；保存逐条用量、原始时间与 UTC 分量、全部必要定位证据 | fork 时间改写、原始来源晚到、双格式别名、相同 tokens 的不同真实响应、重扫幂等 |
| 价格同步和计价 | 解析 models.dev 最新 tiers／modes；内置 JSON 改 tier 行；逐分项推导缺少的组合价格，保留依据；同步重算用量单价与金额 | 普通／Fast 日期回溯、输入输出倍率不同、缺失／零价格、上下文阈值边界、明确报价优先 |
| 查询与统计 | 明细返回可空 response_id、turn_id、source_ordinal、tier、hour、minute；日缓存从逐条事实重建；支持按规定时间桶聚合的存储与索引 | 23:59／00:00 边界、缺失时间、非整小时偏移时区、夏令时重复小时；token／金额聚合前后总量一致 |
| API 与额度 | API 日桶只作内存未知模型参考差额；历史窗口按已观测范围查询本地用量，稳定结果缓存 | 本地 remote 记录不重复补量；不从总 tokens 推算金额；额度归属近似不影响日／小时／分钟事实 |
| App／CLI 与迁移 | 共用 Core 新模型；现有明细和 CLI JSON 适配逐条语义，新时间字段可供查询；未上线旧聚合数据重扫重建 | 不将旧汇总拆成伪请求；不修改 Codex 源日志；当前页面能核对数据，不新增精细 UI 要求 |

主要涉及 `TokenTick/Core/Storage/StoreSchema.swift`、`UsageStore+Turns.swift`、`UsageStore+Collection.swift`、`UsageStore+Queries.swift`、`UsageStore+Statistics.swift`、`UsageStore+API.swift`、`TokenTick/Core/Collection/RolloutParser.swift` 和 `TokenTick/Core/Pricing/`，以及对应共享类型和测试。按职责修改现有实现，不另建一套 App／CLI 逻辑。

以上范围已实施。137 项测试覆盖新结构、迁移、去重、计价和缓存；真实日志、App／CLI 验证见 [优化验收](optimization-validation-20260911.md)。

