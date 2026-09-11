# 逐条用量与 tier 价格优化验收

日期：2026-09-11。范围以 [需求](requirements.md)、[方案](usage-and-tier-pricing-plan.md) 和 [目标](goal.md) 为准。此次优化不包含 UI 美化。

## 已实现

- 每条有效消耗保存一行，分开真实 `response_id`、`turn_id` 和 `source_ordinal`。缺失字段保留 NULL，源 rollout／行号必存；增加 UTC `hour`／`minute` 及日期复合索引。
- turn 负责最早来源所有权，fork 整轮副本不进入 usage。较早原始来源晚到时事务替换；轮内现代响应和旧累计报告绑定后只计一次，同 tokens 的不同响应分别保留。移除业务 `dedup_key` 和 turn 汇总专用字段。
- 价格与默认 JSON 改为 model／date／tier 行；标准和 Fast 分开维护。采用 models.dev `cost.tiers` 和带 service_tier 的 `experimental.modes`；缺组合费率按标准长上下文各分项倍率推导，保留证据，明确 mode 阶梯优先。单档位暂支持一个上下文阈值。
- API 每日桶与账号摘要只保留当前进程内存，CLI `api-usage` 即时获取。差额包含已落盘的未知模型和 remote 用量扣除，负差额显示零并保留实际差异，不写入事实或金额。
- 额度窗口按既有七天观测方案计算，本轮新增本地 tokens／金额及未定价用量。跨界 turn 按开始时间近似归属，相邻窗口使用半开区间；缓存随额度证据、用量、计价与归属变更失效。
- v10 保留并拆分历史价格；同日接口刷新允许更新同日快照。v11 按未上线项目授权清理旧聚合、游标及缓存后重扫；v12 删除旧 API 日桶。无自动备份，不修改源日志。

## 测试与实际数据

完整 Swift 测试：137 项、22 个 suite 通过。覆盖早期来源晚到、fork 时间改写、双格式不同 ordinal／累计基线、相同 tokens 的不同响应、重扫与文件替换、UTC 跨日及非整小时偏移、分项价格倍率、缺价、日期历史、迁移幂等／失败回滚、API 内存与覆盖量、窗口边界／账号范围／缓存失效。日志：`.build/logs/optimization-final-tests.log`。

真实 CODEX_HOME 扫描 1,555 个文件、9,324,833,130 bytes，采集问题为 0。初次新增 120,898 行，排除 47,776 条重复报告／副本，17,534 次身份或证据补齐。随后增量读取 2 个正在追加的文件、185,275 bytes，1,553 个未变化文件跳过；新增 5 行，无重复新增或采集问题。

重扫后审计库有 120,903 行、14,217,019,972 tokens。数据库完整性为 `ok`；没有任何非空 turnId 对应多个 usage 任务；全部 hour／minute 与 UTC 时间一致。

| AIChat 样本 | 独立读取日志汇总 | 数据库 |
| --- | ---: | ---: |
| 原始任务 `01a04139-b2cc-76a3-9906-0df67875f49b` | 454,464,516 | 454,464,516 |
| fork `01a06b33-4bc1-78b0-9777-9bb5137049d2` 的新增 turn | 43,009,157 | 43,009,157 |
| 纯副本 `01a06bb5-ab64-7f13-9702-3b2a5bce260e` | 0 | 0 |

专项 turn `01a0652a-d388-7251-8f78-2208dd7c0964` 保存 11 行、2,192,350 tokens。现代 ordinal 17828 与旧 ordinal 17830 的对应消耗只计一次。独立脚本及结果保存在 `.build/audit/optimization-20260911/verify_aichat.py` 和 `independent-aichat.json`，不提交私人日志。

在审计库清除缓存版本并持有写锁，强制 CLI 直接读取已提交事实；与此前缓存逐字段比较，总览、189 个日桶、1,282 个任务、56 个项目、11 个模型分组全部一致。见 `cache-verification.json`。

models.dev 实际同步得到 48 个模型、56 条 tier 快照；四个图像模型没有本统计所需价格，报告保留。重算 120,903 行，117,237 行完整计价，3,666 行仅因模型缺失而未定价；没有用量无效或金额溢出。已知金额 11,914,766,064,050 纳美元（约 $11,914.77），属于公开 API 价格等值估算。

API 实际读取成功。以 2026-09-10 为例：API 286,899,797 tokens，本地覆盖 273,353,201，参考差额 13,546,596。历史账号覆盖和 API 日桶时区仍未完全确认，因此标记参考估计，不能视作精确其他设备账单。审计库返回 61 个历史观测窗口，带本地用量与金额；窗口使用率始终是最后观测值，不冒充重置前最终值。

## 构建与运行

Debug App／CLI 构建通过；Release App／CLI 构建、arm64 架构与 ad-hoc 签名校验通过。最低系统 macOS 26，验收使用当前 macOS 27 设备，无付费 Developer Program 或公证步骤。构建日志位于 `.build/logs/optimization-app-build.log`、`optimization-cli-build.log`、`optimization-release.log`。

本轮没有可用的 Computer Use 工具，因此未新增原生点击／截图验收；此前用户已验证菜单栏设置入口和恢复主窗口。本轮运行验证只记录进程、数据连接与共享 CLI 的实际结果，不将进程启动称为界面交互已验收。

本机默认库已完成 v10–v12 迁移及全来源同步：1,555 个文件、120,937 条逐条用量，14,221,136,634 tokens；3,666 条缺模型，其他全部完整计价。生成 5,306 条统计缓存，API 返回 197 个每日桶但不落库；完整性 `ok`，AIChat 样本数值与独立审计库一致。差于审计库的新增量来自本轮持续追加日志。同步耗时 210.20 秒，峰值 RSS 185,810,944 bytes（约 177 MiB），无采集、重算或同步错误。原始证据：`main-sync.json`、`main-sync.stderr`、`main-verification.json`。

新版打包 App 已启动并确认打开默认数据库，进程运行正常。Release CLI 从默认库返回 `usage_event` 明细，包含 responseID、turnID、sourceOrdinal、tier 和 UTC hour／minute。包与运行路径记录于 `app-runtime.json`。本轮验证包标记 `source_dirty=true`，含本轮尚未提交的实现，不冒充干净提交构建或 GitHub 发布产物。
