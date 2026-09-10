# 项目名称与任务切换验证

日期：2026-09-10。用户确认项目名优先采用 Codex 中的名称，缺失时才使用文件夹名。

- 显式 projectless 保存为 `Chat`，中文显示“无项目聊天”；不会因为聊天有 cwd 就把它挂到某个项目。
- 缺失名称时优先项目 rootPaths，再根目录提示，最后 cwd；已知项目内的源码子目录不会覆盖项目根目录名称。Codex 项目名仍高于文件夹名，目录匹配仍遵守最长根路径与歧义保留原则。
- 直接更新 `threads.project_name`，用量通过 thread ID 查询最新映射。统计触发器使所有受影响时区缓存失效；历史请求不新增、不修改 token、金额、时间和证据。没有新增 schema 或迁移备份。
- 当前实际数据核对：296 个有用量但无项目名称的任务中，179 个明确标记 projectless，117 个有 cwd 且未标记 projectless；不会把后者全部猜成 Chat。

39 项专项测试、4 个 suite 通过，覆盖名称优先、远端 Windows 路径不误匹配本机目录、缺名称根目录回退、worktree 提示、projectless 覆盖 cwd、歧义、最新 Codex 映射，以及项目 A → B → Chat → A。每次切换都验证旧项目不再计量、直接查询与重建后的缓存一致、明细使用最新项目、usage 原始记录完全不变、重复刷新不写入。

真实验证库同步更新 355 条任务映射；有用量的 Chat 包含 179 个任务、11,359 条请求、1,310,412,177 tokens，未归属项目的任务数降为 0。原有 169,173 条 usage 的全部字段哈希完全不变，活动日志另增 65 条；项目缓存的记录数、tokens 和金额总计与直接 SQL 完全一致，重复扫描没有重复用量，本次同步无问题且没有触发历史金额重算。

App／CLI 的 arm64 Release 构建、ad-hoc 签名与带 JSON 资源的分发包验证通过，独立 CLI 实际运行上述同步。Debug App 已重新构建启动，采用同一映射规则。当前锁屏，未追加原生点击验收；测试与数据库核对已完成。证据留在忽略目录 `.build/audit/default-pricing/`，不提交用户数据库或 Codex 状态文件。

Remote 数据中的 4 个任务（4,995 条、634,730,047 tokens）带 Windows 工作目录，项目按原始路径提取为 `AutomaticDSP`，模型继续为 NULL；不会误归到 TokenTick 或 Chat。Windows 盘符／UNC 是日志数据格式处理，App／CLI 仍仅支持 macOS Apple Silicon。
