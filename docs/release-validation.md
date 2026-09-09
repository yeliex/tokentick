# Release 本地验证

验证日期：2026-09-10。环境为 Apple M2 Pro、macOS 27、Xcode 27 beta（27A5252f），在 arm64 宿主机运行。App／CLI 源码提交 `3932dac0246a74d7e7d45bf035d673bc5fc68ab8`，本轮另加入打包脚本和文档；包内 `BUILD.txt` 如实标记源码有未提交修改。

## 产物与安装

`script/package_release.sh` 依次构建两个 Release scheme，使用通用 macOS destination。App 与 CLI 均验证包含 arm64／x86_64；CLI 两个架构的 Mach-O 最低系统版本均为 26.0，SDK 为 27.0。Intel 运行与 macOS 26 真机仍待验证。

组装后以 ad-hoc 签名启用 hardened runtime，再检查 App 的完整资源封印和 CLI 签名。初次验证定位到共享 GRDB 资源包在后续 target 构建时增加签名文件，导致 App 原封印失效；最终组装后重新签署外层 App，避免将构建成功误认为签名有效。未使用 `codesign --deep` 递归签署来掩盖嵌套对象问题。

ZIP 包含 App、独立 CLI、安装说明、依赖许可证和构建信息；旁附 SHA-256。实际解压到带空格目录后，校验值、签名和 CLI 执行均通过。CLI 再经 `install -m 755` 复制到隔离安装目录，从 `/tmp` 执行 `status` 成功；动态链接检查仅包含系统库，无源码 checkout 或 Homebrew 动态库依赖。

解压后的 App 使用隔离数据库和禁用自动同步的进程环境实际启动。原生每日视图与 CLI 同范围总量均为 10,496,020,973 tokens；无价格快照时表格显示未知金额，切换金额图表显示缺少计价依据。一次空闲采样 CPU 为 0%，RSS 为 209,520 KiB（约 204.6 MiB），仅是该窗口状态的样本，不能代表扫描峰值或最终内存目标。验证后通过开发脚本恢复默认 App，未修改持久偏好。

Gatekeeper `spctl --assess --type execute` 返回拒绝（退出码 3）。当前没有 Developer ID 签名或公证，不能作为已通过系统信任检查的正式分发版本。签名验证成功只证明包内签名结构和资源封印完整。

## 性能基线

从本机日志创建 APFS 克隆的冻结副本，再建立全新 TokenTick 数据库；不修改 Codex 原始日志。用 `/usr/bin/time -l` 记录解压包内 Release CLI 的峰值 RSS，耗时包含 CLI 进程启动。价格表为空，未运行网络同步，因此这不是已有完整历史价格情况下的计价性能基准。

| 操作 | 耗时 | 峰值 RSS |
| --- | ---: | ---: |
| 首次完整扫描 | 96.10 秒 | 74,694,656 bytes（71.2 MiB） |
| 无变化复扫 | 0.430 秒 | 25,952,256 bytes |
| 追加一条请求后增量扫描 | 0.407 秒 | 26,181,632 bytes |
| 统计缓存重建 | 0.450 秒 | 32,571,392 bytes |
| 总计／日期／任务／项目／模型缓存查询 | 0.014–0.019 秒 | 11.6–11.9 MB |

首次扫描 1,539 个文件、9,165,390,811 解压后字节，插入 168,164 条请求，刷新 1,462 条任务名称映射；零解析问题、零重复请求。此数据集没有 `.jsonl.zst`，不代表 Zstandard 性能基线。无变化扫描跳过全部文件，读取零字节。向预先建立的独立测试 rollout 追加一条 120 tokens 请求后，只扫描 1 个文件、578 字节，插入 1 条；SQL 核对总量准确增加 120，统计总计与事实一致，`integrity_check` 为 `ok`。测试请求明确位于隔离副本，不写入产品默认数据库。

最初的冻结副本保留了 Codex 备份数据库的 WAL 模式、未带 sidecar，系统 SQLite 只读打开时报错。将独立快照转换为 DELETE 日志模式后名称读取成功，再使用新的冻结副本和空库执行上述完整基线。最初的失败日志保留，不把失败扫描作为通过结果。克隆的源日志是逐文件快照，不声称是 Codex 所有文件的全局原子快照。

## 证据位置与剩余验收

- 打包日志：`.build/logs/package-release.log`；Gatekeeper：`.build/logs/release-gatekeeper.log`。
- 完整性能记录：`.build/audit/release-validation-8pl27_le/verification.json`，同目录保存原始 CLI JSON、stderr 与 time 输出；脚本为 `.build/audit/release-benchmark.py`。
- 首次快照问题、原生 App／安装 CLI 查询证据：`.build/audit/release-validation-wl_8ctpb/`。
- 默认 App 恢复：`.build/logs/release-ui-restore.log`。

含用户日志的副本和数据库仅放在被 Git 忽略的本机 `.build` 目录，不随 ZIP 或仓库提交。以上验证不替代 API 日差额口径、完整 UI／无障碍、macOS 26、Intel 真机、正式签名与公证验收，完整目标保持进行中。

## Zstandard、历史价格与表示转换补充验证

同日继续使用 `e49f5cd` 本地包内的 Release CLI；运行前核对该版本到 `ce4fcb4` 的 Core、CLI 和依赖无差异。未修改产品代码，也未重新请求价格。测试以此前冻结日志及数据库为基准，再建立独立副本，复制默认数据库中实际保存的 48 条价格记录（UTC 日期均为 2026-09-09）；没有补造更早日期的价格。

基准 JSONL 数据库先执行 `reprice`。另一个空库保存相同价格，从 1,539 个 `.jsonl.zst` 重新采集。测试准备使用 Zstandard CLI 1.5.7、压缩等级 3、两个工作进程，将 9,165,391,389 bytes 压缩为 4,658,023,999 bytes；这个外部工具仅用于准备输入，产品扫描仍通过绑定的 libzstd 流式解码，不调用解压命令。准备压缩耗时不计入采集时间。

该冻结数据集包含上轮为增量验证写入的 1 条 120 tokens 测试记录；本轮表示转换验证再追加 1 条。它们仅存在于隔离副本，不能计为真实用户用量。

通过双向 SQL `EXCEPT` 比较 168,165 条用量的全部字段（仅排除 SQLite 自增 ID）：请求去重键、归属、tokens、模型、Fast／长上下文标记、日期、费率、分项金额、来源行号和完整证据 JSON 均一致。压缩后没有新增重复记录或解析问题，13,413 个继承事件仍按原逻辑处理。

| 操作 | 耗时 | 峰值 RSS |
| --- | ---: | ---: |
| JSONL 基准库历史价格重算 | 9.869 秒 | 25,640,960 bytes |
| 压缩日志首次采集并计价 | 96.287 秒 | 78,495,744 bytes（74.9 MiB） |
| 静态压缩日志复扫 | 0.336 秒 | 25,133,056 bytes |
| 带金额统计缓存重建 | 0.391 秒 | 32,505,856 bytes |
| 带金额总计查询 | 0.014 秒 | 11,485,184 bytes |
| 物化普通日志并追加一条请求 | 0.346 秒 | 27,295,744 bytes |
| 归档移动后复扫 | 0.328 秒 | 25,198,592 bytes |

其中静态复扫跳过全部 1,539 个文件，读取零字节。随后只对预先建立的隔离测试 rollout 物化普通文件，保留旧压缩兄弟并追加一条请求：普通文件优先，重读 1,387 bytes，识别 1 条旧请求重复且仅新增 1 条／120 tokens。移除旧压缩兄弟并将普通文件移到归档目录后，再次读取零字节；最近扫描位置更新，历史金额保持不变，数据库完整性为 `ok`。这些操作全部发生在独立副本，不改变真实 Codex 日志的压缩或归档状态。

价格覆盖为 3,062 条完整计价请求，金额合计 816.0591496 USD；其余 165,103 条保持未定价（4,995 条缺模型、159,991 条无对应历史价格、117 条 Fast 状态未知）。这不是全部历史的完整成本。真实样本中有 734 条普通、2,328 条 Fast 完整计价请求，没有触发长上下文计价的样本。

针对真实样本未覆盖的组合，执行 `swift test -c release --filter 'UsagePricingTests|PriceStoreTests'`，16 个测试、2 个 suite 全部通过，覆盖普通／Fast／长上下文／组合计价、严格阈值、分项不重复计费、精度／银行家舍入／溢出、未知字段、价格只在变化时新增、不回填早于首个快照的金额和重新计价保留事实。这些是明确标记的测试输入，不作为真实使用记录。

原始证据位于 `.build/audit/compressed-release-8zwdg2zg/verification.json` 及同目录的 CLI JSON、time 和 stderr；脚本为 `.build/audit/compressed-release-benchmark.py`。运行日志 `.build/logs/compressed-release-benchmark.log`，Release 价格测试日志 `.build/logs/release-pricing-tests.log`。这关闭了压缩日志及现有历史价格的本机 Release 基线缺口，不替代多设备 API 对账、完整原生 UI 和外部平台／分发验收。
