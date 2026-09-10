# App 运行资源验证

环境：Apple M2 Pro、macOS 27、Xcode 27 beta。使用通用 Release App 的 arm64 进程，数据为既有冻结日志的独立 APFS 副本及隔离 SQLite；不扫描或写入产品默认数据库。测试输入包含 1,539 个 rollout 文件，其中 1,538 个压缩文件和一个普通 fixture，预期 168,166 条用量、20,534,374,503 tokens、816,059,149,600 纳美元。

## 文件通知触发自身扫描

2026-09-10 的 `6a66f3f` 基线运行发现：首次同步后文件未改变，但 App 约每 10.5 秒再次执行本地扫描，每次报告读取 0 字节。独立 FSEvents 观测在同一时刻仅记录 `state_5.sqlite-shm` 的变化（`0x00011400`）。

`ThreadCatalogReader` 已使用 SQLite 只读连接，但 WAL 读者仍可更新共享内存中的同步状态；原监听器接受所有 `state_` 前缀事件，因而将自己的读取误当成新数据，扫描结束后继续触发扫描。修复只排除 `state_*.sqlite-shm` 事件，保留数据库主文件、WAL、日志、任务目录映射以及丢失事件后的完整核对。没有启用会忽略活跃 WAL 的 immutable 读库方式，也没有延长正常扫描间隔来隐藏问题。

原生文件事件回归测试验证：更新现有 SHM 文件不会通知扫描，随后更新 WAL 和主文件仍能通知；原有新增目录、日志追加和归档测试保持通过。`AutomaticSyncTests` 共 6 个测试通过，日志 `.build/logs/watcher-shm-tests.log`；修改后的通用 Release App 构建通过，日志 `.build/logs/watcher-shm-release-build.log`。

## 正在进行的运行采样

- 驱动脚本：`.build/audit/app-resource-profile.py`。按 0.5 秒采样 App PID 的 RSS、`ps` CPU 百分比及累计 CPU 时间，并保存每次完成的同步报告；不将 profiler 或 Codex app-server 子进程用量算入 App。
- 修改前基线：`.build/audit/app-resource-a3hqhkul/`。首轮同步报告耗时约 103.739 秒，采样在约 105.644 秒观察到完成，扫描约 9.165 GB 解压后数据，本地问题数为 0。首轮随后继续十分钟采样；最终完整性和逐字段核对以成功生成的 `verification.json` 为准。
- `file-events.log` 保存导致反复扫描的原始文件事件，`samples.csv` 保存曲线数据，`reports.json` 保存完成报告。Mac 在采样期间锁定，后续稳态属于后台观测，具体边界记录在 `ui-observations.json`。
- 冻结 Codex 目录未包含认证文件，API 阶段报告 `-32600`；该隔离限制不能冒充真实账号 API 性能。价格沿用既有历史快照，自动同步仍按产品逻辑执行。
- 修改后需用相同输入重跑，确认恢复定时补扫且全部用量字段不变。采样峰值不是未采样瞬间的绝对峰值，短期后台曲线也不代表长时间前台交互或 macOS 26／Intel 验收。

当前尚不将 App 资源验收标记为完成；待保存修复后的对比和持续运行结果。
