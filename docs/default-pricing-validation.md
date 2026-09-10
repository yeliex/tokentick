# 默认价格、迁移与 Fast 证据验证

日期：2026-09-10。范围对应用户本轮三项更正；原完成审计保留之前的验证事实，当前计价和迁移规则以本文件及需求文档为准。

## 已实现的规则

1. `TokenTick/Core/Pricing/openai-default-prices.json` 随 Core 资源包分发给 App 和独立 CLI。包含 65 个模型／快照配置，其中 61 个有 token 费率；4 个没有公开 token 费率的图像模型保持空值。补入 GPT-5.1／5.2 Codex、Codex Mini、o1 Mini／Preview 等旧条目。只支持明确列出的名称，不用前缀把未知模型映射成已有价格。
2. 有效数据库价格历史优先，保留此前最早快照覆盖更早历史的规则；模型不存在或选中快照全部费率缺失时采用内置默认价。默认价核验日不等于历史生效日。单项费率缺失不拼接另一套计价规则。请求证据记录采用的来源、日期和 `bundled`，JSON 内容变化触发历史重算；网络失败不阻止本地重算。
3. 迁移不再创建备份目录或复制数据库。跨进程写锁、兼容性检查、GRDB 事务与回滚继续保留。旧版备份的容量展示和 Finder 定位保留，不自动删除用户已有文件。
4. Fast 优先取 rollout 明确值；缺失时读取同一 CODEX_HOME 的 `logs_*.sqlite`，按 thread ID + turn ID 查 websocket 请求或实际轮次提交。仍无证据则按普通费率。原始 `is_fast` 保留 NULL，`evidence_json.pricingMode` 说明 rollout、trace 或 default_standard。额外日志只保存轮次、任务、文件名、行 ID、时间及类型，不复制正文；后到的证据重算该轮次，明确普通的 rollout 不会被覆盖。
5. trace 证据与行号游标原子提交，识别文件替换、截断和行号复用；逐行解析并按 256 行提交，单条正文超过 4 MiB 时跳过补证，不影响 rollout 采集与普通费率兜底。监听 trace 主库及 WAL，忽略只读连接产生的 SHM 事件。

## 来源

- [OpenAI 官方价格表](https://developers.openai.com/api/docs/pricing) 的 Standard／Fast token 表，以及 [GPT-5.2 Codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex)、[GPT-5.1 Codex](https://developers.openai.com/api/docs/models/gpt-5.1-codex)、[Codex Mini](https://developers.openai.com/api/docs/models/codex-mini-latest) 等旧模型官方条目；每个内置配置保留自己的来源 URL。核验日期为 2026-09-10，未知 Fast／上下文组合没有按通用倍率补猜。
- [models.dev API](https://models.dev/api.json) 当前 OpenAI 目录作为默认目录基础，在线更新继续保存到 SQLite。
- [CodexBar Fast 补证源码](https://github.com/steipete/CodexBar/blob/d8fa1d545df1e0cc69b6d01e1e131e7b4b6110ee/Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner%2BCodexPriority.swift)：参考 websocket、Submission 及增量 SQLite 读取；TokenTick 额外约束实际轮次操作和任务身份，避免把 ThreadSettings 提交 ID 或正文嵌套字段当作证据。

原始公开资料保留在本地忽略目录 `.build/research/`，真实数据及核对结果保留在 `.build/audit/default-pricing/`，不提交数据库或私人日志。

## 测试与真实数据

- Core 全量 115 项测试、21 个 suite 通过。新增默认旧模型、API 历史优先、未知模型、Fast 晚到补证、显式普通优先、重复读取、行号复用和正文排除；迁移验证成功保留历史且无备份、失败回滚、未来 schema 拒绝。
- FSEvents 专项 7 项测试通过，数据库／WAL／SHM 测试同时覆盖 `state_5` 和 `logs_2`。最终默认价格专项另覆盖接口条目存在但全部价格为空时的默认价回退。
- 在此前已存在的历史验证库上同步，无额外备份。原有 168,898 条记录的 ID、token、时间、归属等非计价字段哈希完全一致；活动日志另增 275 条，因此最终 169,173 条、20,683,838,672 tokens。
- 重算前完整计价 91,035 条；重算及增量同步后完整计价 164,178 条，剩余 4,995 条全部缺模型。没有因缺 Fast 而未定价的记录，无非法用量、溢出或采集问题。598 条采用内置价格；283 条轮次级 trace 证据用于 386 条请求，72,495 条完整计价请求采用默认普通模式。
- 全局已知金额为 16,759.05927378 USD，属于公开价格换算值，包含默认普通和默认历史价格估算。总览、每日、模型、任务、项目五个缓存维度的记录数、token 与已知金额均和直接 SQL 总计一致；SQLite `integrity_check=ok`，已有备份清单未变。
- Release 独立 CLI 从单独安装目录加载相邻价格资源包并执行上述同步。单次含扫描、补证、重算及缓存重建约 42.53 秒，峰值 RSS 47,759,360 bytes；这是本机一次测量，不承诺其他数据规模的耗时。

## 构建与运行

App 与 CLI 的 arm64 Release 构建、ad-hoc 签名校验及 ZIP 打包通过；CLI 安装说明同步增加价格资源包复制。Debug App 已重新构建启动，在默认数据库自动补证和重算。当前 Mac 锁屏，原生界面截图／点击验证未执行；本轮通过测试、独立 CLI 与数据库核对确认计价行为。

## Remote／其他用量口径

用户说明剩余模型缺失记录来自 Codex remote 的其他设备用量，不再作为必须恢复模型的待办。实际库中这 4,995 条是已落盘 rollout 的 `token_count`，日期 2026-06-12 至 2026-06-14，已有 4 个任务 ID，账号未知，合计 634,730,047 tokens；采集来源 `local` 表示从本地文件读取，不代表最初一定在本机产生。保留这些事实，`model=NULL` 统一显示为“其他”，继续参加全局 token 汇总，按账号筛选仍遵循明确匹配规则；不清空已有任务映射，不补猜金额。

当前实际 `account/usage/read` 响应包含 196 个只有 `startDate`／`tokens` 的日桶和 lifetime 等摘要，`threadUsage=null`，没有金额。未来可比 API 总量只能补差额到“其他”，不可直接相加；不能把缺模型的 634.73M tokens 再当作独立 API 增量重复入账。金额补齐须先有实际来源及口径。
