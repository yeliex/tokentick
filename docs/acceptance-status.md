# TokenTick 验收状态

核对日期：2026-09-10。初次审计基线为 `86d23ca`，后续实现与验证按各项补充；环境为 Apple M2 Pro、macOS 27、Xcode 27 beta。完整目标仍未完成。

本表按需求保留功能和验证边界。测试通过只证明对应输入和环境；缺少服务端口径、真实系统或交互证据的项目继续列为未完成。

## 数据与工程

| 范围 | 当前证据 | 状态与剩余条件 |
| --- | --- | --- |
| SwiftUI App、共享 Swift Core 和 CLI | `TokenTick.xcodeproj` 的两个 target；`Package.swift` 的 Swift 6、macOS 26、GRDB 7.11.1、libzstd 1.5.7；App／CLI 的 Debug 和通用 Release 构建 | 本机构建已验证；macOS 26 与 Intel 真机运行尚未验证 |
| 活动／归档日志、稳定 rollout 身份 | `RolloutIdentity`、`LocalUsageScanner`；身份与扫描测试；冻结 JSONL／Zstandard 数据的全部用量字段双向比较 | 已验证普通与压缩表示、归档移动、静态跳过；不承诺未采集且已删除的来源能够恢复 |
| fork／revert、新旧用量事件去重 | `RolloutParser`、采集存储事务；`RolloutIdentityTests`、`LocalUsageScannerTests`、`SettingsAttributionTests` | 已验证继承边界、复制前缀、新旧记录升级和重放；缺少可确认边界时报告问题而非猜测归属 |
| 半行、截断、替换、坏行、扫描恢复 | `scan_files` 的持久游标与解析状态；批次失败和重启测试；压缩损坏与超大正文测试 | 扫描恢复已验证；不将它扩展为所有维护命令都具备断点恢复 |
| 任务／项目最新映射和统计证据 | `ThreadCatalogReader`、`DesktopProjectCatalog`、用量明细查询；目录映射、重命名、未知值、证据字段测试 | 本机与测试输入已验证；未知账号、模型或模式保持空值 |
| SQLite、迁移、备份、未来 schema 拒绝 | `StoreSchema`、`UsageStore`；迁移备份、无 sidecar 恢复、未来版本及存储容量测试 | 已验证现有迁移路径；真实升级包和后续迁移仍须按版本验收 |
| 历史价格与四种模式分项金额 | `ModelsDevPrices`、`UsagePricing`、价格存储；日期、阈值、组合、精度、溢出、未知分项测试；48 条实际价格快照重算 | 已验证支持规则；首个快照之前及无可靠模式／价格的数据继续未定价 |
| 金额重算的持久断点 | `RepriceRecoveryTests` 验证批次与进度原子提交、重开恢复和依据变化后重算；10 万条隔离输入的 Release CLI SIGKILL 恢复 | 已验证金额重算，见 [维护任务恢复](maintenance-recovery.md)；统计缓存重建另行验收 |
| 统计缓存重建的持久断点 | `StatisticsRecoveryTests`、v4 迁移与备份测试；10 万条 Release CLI SIGKILL 续算；168,165 条历史副本的新旧全部字段比对 | 已验证批次原子提交、最终原子发布、过期进度废弃、多时区隔离和整数溢出，见 [维护任务恢复](maintenance-recovery.md) |
| 多维统计、日期／时区、分页、NULL | `UsageStore+Statistics/Queries/Records`、`StatisticsSQL`；统计、筛选、记录及 DST 测试；真实数据与直接 SQL 比对 | 任务／日／项目／模型及交叉查询已验证；API 差额尚未接入 |
| App／CLI 同时读取和写入 | 同一 `FileWriteLock`、WAL；并发扫描、取消等待、过期缓存测试；新 CLI 与持锁写者独立进程验证 | 已验证已提交快照与旧缓存隔离，见 [Release 验证](release-validation.md) |
| 服务端日桶和额度历史采集 | `CodexAPIClient`、API 存储与查询；真实 196 个日桶；状态失败、账号切换、reset、最新快照及分页测试 | 采集与独立查询已实现；当前 CLI 仍为 0.152.1，日对账和周期金额的契约缺口见下表 |
| CLI 安装与独立运行 | `cli.swift` 共用 Core；ZIP 解压、隔离安装、`--help`／`status` 和扫描／查询基线 | 本机已验证；没有将私钥、Codex 凭据或日志副本放进分发包 |

2026-09-10 初次审计执行 `swift test`：98 个测试、17 个 suite 全部通过，日志 `.build/logs/acceptance-core-tests.log`。加入金额重算恢复后为 101 个测试、18 个 suite；加入统计恢复和迁移验证后，全量 107 个测试、19 个 suite 全部通过，最新日志 `.build/logs/statistics-recovery-full-tests.log`。上述测试覆盖的分支不代表未知上游格式和外部环境已经验收。

## 明确未完成的功能

| 要求 | 当前实现及证据 | 需要完成的工作 |
| --- | --- | --- |
| 服务端每日总量补差、后补本地记录缩减差额 | 日桶单独保存，不创建差额记录；`docs/api-reconciliation.md` 保存实际响应和契约缺口 | 确认账号、日边界、token 包含关系和服务端覆盖后，实现正差额幂等更新、本地回补、负差额报告；当前不能据正差值猜测跨设备用量 |
| limit 周期的 tokens 和分项金额 | 周期边界、百分比、来源和查询已实现；tokens／金额保持 NULL | 取得请求到额度桶的归属依据后实现周期聚合；不能按模型名或百分比推算 |

## 客户端、性能与分发

| 范围 | 当前证据 | 剩余验收 |
| --- | --- | --- |
| 总览、每日、任务、项目、明细、额度、状态和设置 | 真实数据绑定；深色与浅色主要页面的 Computer Use 截图及多项交互；详情逐字段 AX 标签 | 完整 Tab 遍历、VoiceOver 实际朗读、所有窄窗口状态仍未完成 |
| 菜单栏和关闭主窗口后的行为 | 单模板图标；当前账号主／次额度、重置和同步状态；`86d23ca` Debug 构建通过 | 本次 Mac 仍锁定，无法实测关闭后恢复主窗口、菜单设置入口及键盘操作；已有解锁请求待响应 |
| 自动同步和恢复运行 | 调度、取消安静期、文件事件测试；隔离 App 自动追加／归档／补扫验证 | 真实系统睡眠／唤醒及完整开关交互尚未完成 |
| 图标和原生外观 | App 已接入 `.icon`，通过布局补偿边距消除额外外框，原图不变；Debug／Release 包内明暗引用和八张导出预览已验证，见 [系统级应用图标](app-icon.md) | Dock／Finder 实际外观切换及 macOS 26 真机仍待验证；渲染代际预览不能替代真实系统 |
| 文件与 SQLite 性能 | 冻结 1,539 文件、约 9.17 GB；JSONL／压缩首次扫描约 96 秒、峰值约 71／75 MiB；静态复扫零字节；跨进程读者约 11 ms | 这些为当前机器和输入的基线；App 扫描期间及长时间运行的内存／CPU完整曲线尚未采集 |
| Developer ID、打包和安装 | App／CLI 双架构签名、时间戳和 hardened runtime 验证通过；已验证的干净源码签名包 `signed-L4pz8J/TokenTick-0.1.0-signed-ffaa27bde7a0.zip` | 尚未公证，Gatekeeper 返回 `Unnotarized Developer ID`；可用 notarytool profile 名称待确认，本任务未发起公证提交 |
| 最低系统与架构 | 产物最低系统为 macOS 26.0，包含 arm64／x86_64 | macOS 26、Intel 真机仍需外部设备验证，不能用宿主机 macOS 27 的结果替代 |

## 收尾顺序

1. 图标已接入并完成构建和导出验证，继续原生系统外观验收；维护任务恢复已按独立测试、进程终止和历史副本验证。
2. Mac 解锁后继续菜单、键盘、VoiceOver、睡眠恢复和运行资源验收；有实际问题再修正对应实现。
3. 获得公证 profile 后验证认证，按当时已验证的提交生成签名候选并提交公证，保存任务 ID 和结果，再验证最终分发包。
4. API 对账与周期归属等待明确数据契约；macOS 26／Intel 等待对应设备。任何一项缺失都不将整体目标标为完成。
