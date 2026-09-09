# 维护任务恢复

日志采集、金额重算和统计重建分别维护自己的事务边界，均保存持久进度。以下区分金额写回和统计缓存最终发布的恢复方式。

## 金额重算

App 与 CLI 继续调用共享的 `repriceUsage(fromDate:)`，无需额外的恢复参数。每批最多 512 条，保持原有分项计价、空值和事实保留规则。

内部 `app_metadata` 的 `reprice_checkpoint` 保存最后已提交用量 ID、范围、累计报告、事实版本、价格快照摘要和断点格式版本。它不是业务价格版本，不改变 `prices` 或 `usage` 的字段，也不需要新增业务表或修改已有迁移。

恢复规则：

1. 取得与采集、迁移相同的跨进程写锁，读取当前事实版本和价格依据。
2. 范围、版本及价格摘要均一致才使用断点；用量或项目归属变化、价格变化、调用范围变化、旧版或不可解码断点都从头核对。现有金额和来源不会因为断点失效而删除。
3. 同一事务写入本批金额及断点。自身计价也会推进事实版本，因此断点保存本批写入后的版本；不能把自身更新误判成下一次恢复的外部修改。
4. 进程终止或某一批失败时，仅丢弃未提交批次。累计报告随断点保存，恢复完成后报告覆盖同一逻辑重算的全部批次。
5. 没有剩余记录时清除断点。下一次显式重算从头检查全部所选用量；未变的价格和金额不会重复增加统计。

价格摘要通过有序 SQLite 游标逐条处理全部快照的费率、阈值和原始规则，不把历史价格全集加载为数组。计算规则或断点格式修改时，需要递增内部断点版本使旧进度失效。

## 验证

`RepriceRecoveryTests` 在 1,025 条隔离输入上覆盖第二批失败后重开数据库恢复、断点写入失败时金额与事实版本一同回滚，以及用量、价格、范围、版本或损坏 JSON 导致的重新核对。报告计数也核对此前批次，不能仅看最终金额相同就认定发生了恢复。

2026-09-10，macOS 27／Apple M2 Pro 上使用新构建的 Release CLI 进行真实 SIGKILL 验证。独立数据库保存 100,000 条明确标记的测试用量及一条从既有价格库复制的真实价格快照，不修改 Codex 原始日志或默认产品数据库：

- 第 512 条已提交后强制终止进程，持久游标、已计价记录数和累计报告均为 512。
- 新进程恢复后报告 examined／changed／fullyPriced 均为 100,000；每条金额为 10,100,000 nanoUSD，token 总量为 110,000,000，最终金额和 SQL 汇总一致。
- 完成后断点消失，`integrity_check` 返回 `ok`。恢复耗时约 16.74 秒，峰值 RSS 为 22,134,784 bytes；这些是全部需要计价的人工输入，不能直接与真实历史中大部分缺价格的重算基线比较。

脚本：`.build/audit/reprice-process-recovery.py`。断点、报告、time 输出和 SQL 核对位于 `.build/audit/reprice-kill-w8ds8x9k/`。专项测试日志 `.build/logs/reprice-recovery-tests.log`；App Debug 与 CLI 通用 Release 构建日志分别为 `.build/logs/reprice-recovery-app-build.log`、`.build/logs/reprice-recovery-cli-build.log`。

## 统计缓存重建

App 与 CLI 共用 `rebuildStatistics`，每批按用量 ID 读取最多 8,192 条，在 SQLite 内复用已有统计 SQL 聚合，再将中间结果写入 `statistics_rebuild`。该表由 `v4.statistics-recovery` 迁移创建，属于内部恢复数据；升级前沿用一致备份，不修改已有七张业务表、事实或金额重算断点。

每个时区在 `app_metadata` 的 `statistics_rebuild_checkpoint:<时区>` 保存最后提交 ID、事实版本和内部断点版本。批次聚合与断点同一事务提交；每批重新核对事实版本。用量变化、项目重新归属、旧版或损坏断点会废弃该时区的中间结果并从头重建。其他时区的中间结果不受影响。

所有批次完成后，以 `SUM` 合并相同日期、账号和维度，并在一个事务内替换正式缓存、发布缓存版本、清理暂存和断点。全空分项仍为 NULL，跨批次整数溢出会报错，不通过转为浮点数完成发布。进程退出、批次失败或最终发布失败都保留此前提交的进度和旧缓存。查询不使用暂存表，发现正式缓存过期时仍读取已提交事实。

`StatisticsRecoveryTests` 覆盖第二批失败后重开续算、禁止重复执行已完成批次、多时区隔离、断点写入回滚、最终发布失败后仅重试发布、依据变化后重建，以及跨批次金额溢出。结果逐字段与原有直接聚合 SQL 比较。`UsageStoreTests` 另验证 v3 升级前后的事实、正式缓存、内部元数据和迁移备份一致。

2026-09-10 的 Release CLI 真实进程验证使用独立数据库中的 100,000 条明确标记测试用量：

- 第 8,192 条中间聚合提交后 SIGKILL，断点 ID 和暂存记录数一致；正式缓存仍完整保留。
- 新进程在禁止重复执行已提交批次的测试触发器下成功续算，完成后暂存与断点清空。10 万条用量合计 110,000,001 tokens、1,010,000,000,000 nanoUSD，缓存与事实一致。
- 恢复约 0.108 秒，峰值 RSS 22,151,168 bytes；这是维度较少的测试输入，不能代表真实历史的聚合耗时。

另外，对冻结历史库的两个独立副本分别运行修改前和修改后的 Release CLI：168,165 条用量（包含此前标记的一条测试记录）、4,514 条 Asia/Shanghai 缓存，新旧用量和缓存全部字段双向 SQL 比对一致。单次重建分别约 0.419／0.431 秒，峰值 RSS 32,505,856／23,085,056 bytes。新版本首次打开副本的约 0.641 秒另含迁移和备份，不计入重建耗时；单次测量仅作本机基线，不据此承诺稳定性能收益。两项 `integrity_check` 均为 `ok`。

证据脚本为 `.build/audit/statistics-process-recovery.py`、`.build/audit/statistics-release-benchmark.py`，输出分别在 `.build/audit/statistics-kill-mdmfu2mz/` 和 `.build/audit/statistics-benchmark-gjnun1fo/`。Core 全量 107 个测试、19 个 suite 通过，日志 `.build/logs/statistics-recovery-full-tests.log`；App Debug 与 CLI 通用 Release 构建通过，日志分别为 `.build/logs/statistics-recovery-app-build.log`、`.build/logs/statistics-recovery-cli-build.log`。本次不修改 Codex 日志或默认产品数据库，App 原生交互仍待解锁后的独立验收。
