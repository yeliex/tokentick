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
