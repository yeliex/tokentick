# 自动更新验证（2026-09-15）

## 实现范围

- 参考 Shuttle，接入 Sparkle 2.9.6、每小时自动检查、应用菜单／菜单栏／关于页检查入口及自动检查开关。
- Core 和 CLI 不链接更新控制器；App 单独使用 `TokenTickUpdates`。
- 发布脚本生成 App／CLI 分发包、仅 App 更新包及 SHA-256，签名脚本生成带 Ed25519 签名和 Markdown 发布说明的 appcast。
- GitHub 标签工作流完成构建、签名和 Release 发布；仓库已公开，签名私钥已配置为 Actions Secret，源码只包含公钥。

## 已完成验证

- Debug App 构建通过：`.build/update-debug-build.log`。
- Release App／CLI 构建、arm64 检查、嵌套代码签名校验、CLI `--help` 通过：`.build/update-package.log` 和 `.build/logs/release-*-build.log`。
- 本地生成 appcast，核对版本、构建号、最低系统、arm64 条件及更新 ZIP URL：`.build/update-appcast/appcast.xml`。
- 使用 `Info.plist` 公钥独立验证 ZIP 的 Ed25519 签名通过；修改包内容后校验拒绝。
- 原生 UI 显示自动检查开关和手动检查入口；未发布线上 appcast 时，手动检查显示获取更新失败。
- 隔离端到端验证使用 `com.yeliex.tokentick.update-validation`、独立数据库和仅监听 `127.0.0.1` 的 HTTP 服务。测试副本从 `0.1.0 (2)` 自动发现 `0.1.1 (3)`，显示发布说明，下载并通过 Sparkle 签名校验，点击“安装并重启应用”后完成替换和重启。安装目录 Info.plist 为 `0.1.1 (3)`，新进程已运行，替换后的代码签名校验通过。测试 App 和服务已停止。
- 本地测试产物、访问日志和 Sparkle 日志位于 `.build/update-e2e/`；测试的本地 HTTP 配置仅修改该目录中的 App 副本，正式 App 使用 GitHub HTTPS 更新源。
- 发布脚本 Bash 语法、macOS 自带 Bash 的参数处理、工作流 YAML 和 plist 解析通过。

## 尚未验证

- 尚未推送标签或发布首个 GitHub Release，工作流没有远端运行记录，正式 appcast 地址目前为 404。
- 尚未验证浏览器下载带隔离属性的首装流程，以及已分发正式版本之间的线上升级。
- 没有变更数据库迁移策略；独立安装的 CLI 仍手动升级。
