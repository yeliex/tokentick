# 当前范围完成审计

> 后续规则更新（2026-09-10）：内置 JSON 价格、无自动迁移备份、额外日志 Fast 证据及默认普通计价见 [最新验证](default-pricing-validation.md)。下文已注明日期的旧验证记录保留当时事实。
日期：2026-09-10。范围依据 [当前目标](goal.md)、[需求](requirements.md) 和用户后续更正。以下区分实现、测试、真实运行证据；历史记录中已撤销的 Intel、付费签名／公证、macOS 26 专机、推算 API 差额及精细 UI 门槛不参与当前判定。

本次 `git diff 854f0ded9a31 HEAD -- TokenTick TokenTick.xcodeproj Package.swift Package.resolved Tests` 无差异：已构建和测试的代码仍为当前代码，后续变更仅为文档和打包提示。没有因文档更新重复执行全量测试。

## 数据及工程

| 要求 | 对应实现与有效证据 | 判定 |
| --- | --- | --- |
| SwiftUI App、独立 CLI、共享 Swift Core | project.pbxproj 两个 target 引用 TokenTickCore；cli.swift 独立入口；两 scheme 的 Debug／Release 构建记录 | 通过 |
| macOS 26+、仅 arm64 | 两构建配置部署目标 26.0、ARCHS=arm64；独立包 App／CLI lipo 检查 | 通过，按当前设备验收 |
| SQLite、可空归属及统计证据 | StoreSchema、TokenUsage、UsageStoreTests；保留 NULL、分项包含关系及来源字段，不保存正文；真实库迁移与原有事实散列一致 | 通过 |
| rollout 身份、归档、压缩与消失 | RolloutIdentityTests、LocalUsageScannerTests 的移动／压缩／截断／替换／冲突副本／静态压缩跳过用例；真实 1,540 文件全扫及增量复扫 | 通过 |
| fork／revert、累计与请求去重 | LocalUsageScannerTests 的继承边界、复制前缀、新旧事件升级、跨重启重复、重复心跳和冲突回滚断言；历史副本原有 168,874 条事实不变 | 通过 |
| 半行、超长正文、坏行及批次恢复 | LocalUsageScannerTests 的半行追加、超长工具记录、坏行修复、失败批次保持游标用例 | 通过 |
| 历史模型与模式证据 | SettingsAttributionTests 覆盖轮次绑定、模型切换歧义、显式 NULL、错误所有权、旧数据幂等补齐及冲突回滚 | 通过；缺失源字段保持未知 |
| 每日价格与首份历史回填 | PriceStoreTests 的变价／不变价、失败不标成功、首份快照向前覆盖及事实不变；真实 models.dev 同步 48 个模型 | 通过 |
| 普通、Fast、长上下文与组合计价 | UsagePricingTests 覆盖四模式、严格阈值三边界、缓存扣除、未知价格、部分金额、精度舍入、溢出、非支持规则和多 tiers | 通过；无依据的组合费率为空 |
| API 日桶独立、账号切换和失败诊断 | CodexAPITests、APISyncStateTests 覆盖前后账号、未知账号、过期响应、部分失败、超时及取消；真实 API 196 日桶；本次 Release CLI 失败退出 1 | 通过；不声明日桶口径已可对账 |
| 历史周额度与全部实时额度 | LimitQueryTests 验证日志单独回填、乱序、漂移不重置、自然／疑似提前重置、时区分页；API 测试确认实时不恢复；真实历史与原生额度页补验 | 通过；最后观测不冒充最终值 |
| 全局／账号、每日／任务／项目／模型 | StatisticsTests、UsageFilterTests、UsageRecordTests 覆盖归属过滤、NULL 哨兵、交叉筛选、搜索、排序、稳定分页、DST／含首尾日期；真实五维直接查询与缓存逐字段一致 | 通过 |
| 最新标题和项目归属 | ThreadCatalog／DesktopProjectCatalogTests、LocalUsageScannerTests 映射更新；StatisticsTests 项目更名使所有时区缓存失效，标题更新不改事实 | 通过 |
| 数据库迁移、备份、拒绝旧程序 | UsageStoreTests 覆盖 v3／v4／v5 迁移和备份、未来 schema 拒绝；实际默认库 v5 升级，原生设置可见迁移备份 | 通过 |
| 重算与缓存持久恢复 | RepriceRecoveryTests、StatisticsRecoveryTests 的事务断点、依据变化及原子发布；10 万条记录 SIGKILL 后新进程续算证据，见 maintenance-recovery.md | 通过 |
| 跨进程读写一致 | FileWriteLock／WAL；并发扫描及取消测试；独立 CLI 在未提交事务和持扫描锁期间读取正确已提交事实，integrity=ok | 通过 |
| 动态 CODEX_HOME、监听与恢复 | 实时 getenv 测试、AutomaticSyncController 每次同步取目录／周期检查重绑、AutomaticSyncTests 原生文件通知和 SHM 排除；当前实际增量只扫描活跃文件 | 通过；其他 shell 的 export 不会修改运行中进程环境 |
| 有界内存及性能基线 | 流式 reader、分批事务、SQL 聚合、UI 分页；真实历史全扫／重算／增量 RSS 与时间，旧代码改动对应的 App 持续运行和唤醒记录 | 通过；记录测量条件，不承诺硬性上限 |

测试证据为 `.build/logs/current-tests.log` 的 110 个测试、19 个 suite，以及随后 `.build/logs/current-history-fixes-tests.log` 的 11 个专项测试。恢复、并发、真实数据的原始输出已回读核对，路径分别见 [恢复](maintenance-recovery.md)、[运行资源](app-performance.md) 与 [本轮验证](validation-20260910.md)。

## 客户端及分发

| 要求 | 证据 | 判定 |
| --- | --- | --- |
| 查询驱动的基础数据 UI | 当前设备总览、历史／实时额度、设置已实际操作；已有每日、任务、项目、记录、筛选和检查器原生验证记录；当前单日与独立 Release CLI 再次比对 | 通过，精细视觉后续迭代 |
| token K／M／B／T、未知与精确值 | UsageFormatting、TokenText；格式边界脚本；当前 UI 显示 61M、456.03K，辅助信息 61,004,858，与 CLI 原始整数一致 | 通过 |
| 设置无目录配置、容量和备份 | 当前应用菜单打开 Settings，只有 CODEX_HOME 说明、自动同步、时区、真实库容量及 2 份迁移备份；StorageSummaryTests 的有界与只读约束 | 通过 |
| 现有图标、原生场景、单图标菜单栏 | TokenTick.icon、资源编译和明暗导出记录；TokenTickApp 的 WindowGroup／Settings／MenuBarExtra 与纯图标 label；不重做品牌 | 实现及资源通过 |
| 菜单栏菜单打开设置、关闭主窗口后恢复 | MenuBarView 的 SettingsLink、openWindow 和 activate 已实现；Computer Use 系统菜单访问超时，用户随后实际操作并回复“已验证，两项都正常” | 通过，用户人工验收 |
| ad-hoc ZIP、CLI 独立运行 | 干净源码 854f0ded9a31 的 ZIP 独立解压、哈希、严格签名、arm64、动态链接检查通过；7 个 CLI 空库命令成功，参数错误退出 2，API 失败退出 1 | 通过，不要求 Apple 公证 |

最新独立包验证：`.build/audit/completion-release-2kvfzeg1/verification.json`。当前单日 App／CLI 对照为 2026-08-17：61,004,858 tokens、65,843,041,600 nanoUSD 已知金额、456,033 未定价 tokens。

## 完成结论

用户已确认菜单栏两条操作链正常，当前范围所有验收项均有对应证据。没有待完成的实现或必要验收项，目标可以关闭。系统菜单由用户人工验收，其他原生窗口和数据核对由本机工具完成，两者分开记录。

历史缺失的账号、模型、Fast、价格和最终周额度百分比继续保持未知；API 日桶不参与未被证明可比的差额计算。这些是已确认的数据边界，不作为未实现功能或虚构补数的理由。完整 VoiceOver、精细视觉、Dock／Finder 明暗切换专项以及额外系统设备测试留待后续明确需求。
