# TokenTick

专为 macOS 开发的 Codex 用量与成本统计工具。SwiftUI App 与独立 CLI 共用 Swift Core、SQLite 数据库和业务逻辑，仅支持 macOS 26.0+ Apple Silicon。

本地日志提供逐条用量事实，按历史模型价格换算美元金额；API 日桶仅作内存参考差额，历史七天额度与当前实时额度分别处理。金额是公开 API 价格等值估算，不是订阅实际账单。

- [需求](docs/requirements.md)：产品范围、功能、客户端约束和验收要求。
- [技术方案](docs/technical-design.md)：表结构、采集去重、价格、API、额度、查询及开发重建。
- [图标资源](assets/icons/README.md)：当前定稿及资源维护。

## 语言

应用支持英文和简体中文，使用 macOS 原生语言选择。英文是开发语言及缺失翻译的回退语言；系统偏好简体中文时显示中文。可在系统设置的「通用 → 语言与地区 → 应用程序」中为 TokenTick 指定语言，重新启动后生效。应用内不提供语言切换。

界面翻译维护在 `TokenTick/Resources/Localizable.xcstrings`；Core 错误提示维护在 `TokenTick/Core/Resources` 的语言目录中，通过 SwiftPM 资源 Bundle 加载。持久化标识与查询值不随显示语言改变。

## 本地开发

使用带 macOS 26 或更新 SDK 的 Xcode，打开 `TokenTick.xcodeproj`。App target 为 `TokenTick`，CLI target 为 `tokentick`；Core 和测试由根目录 `Package.swift` 管理。

```sh
# 构建并运行 App
./script/build_and_run.sh --verify

# 构建 CLI
xcodebuild -project TokenTick.xcodeproj -scheme tokentick \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build
.build/DerivedData/Build/Products/Debug/tokentick --help

# Core 测试
swift test
```

App 脚本还支持 `--debug`、`--logs`、`--telemetry`。产物位于 `.build/DerivedData`，日志位于 `.build/logs`。依赖通过 Swift Package Manager 命令管理，提交其生成的锁文件。

每次操作读取进程当前 `CODEX_HOME`，空值默认 `~/.codex`；没有目录设置项或 `--codex-home`。其他 shell 的 export 不会自动改变已运行 App 的环境。

App 与 CLI 默认共用 `~/Library/Application Support/TokenTick/usage.sqlite`。开发验证用 CLI `--database <路径>` 或 App 环境变量 `TOKENTICK_DATABASE` 指定隔离数据库；`TOKENTICK_AUTOSYNC=0` 关闭本次启动自动同步，用于开发验证。Debug 可用 `TOKENTICK_APPEARANCE=light|dark` 验证外观，Release 不包含此入口。

## CLI

以下示例假设 `tokentick` 已加入 PATH；未安装时可使用构建目录中的可执行文件。

| 命令 | 功能 |
| --- | --- |
| `sync --scope all` | API、日志、价格、所需重算和缓存的共享同步流程 |
| `sync --scope local\|prices\|api` | 同步指定来源 |
| `scan --json` | 只采集本地日志 |
| `usage --group total\|day\|thread\|project\|model --json` | 用量和金额汇总 |
| `records` | 逐条明细及结构化来源信息，返回 JSON |
| `prices`／`sync-prices` | 查询／同步历史价格；独立同步价格后由 reprice 或 sync 更新金额 |
| `reprice`／`rebuild` | 重算金额（支持断点）／事务重建统计缓存 |
| `sync-api`／`api-usage` | 显式获取 API；api-usage 在同一进程计算内存参考差额 |
| `current-limits` | 显式联网读取全部当前额度 |
| `limits` | 查询主桶 codex 的七天历史窗口、最后使用率及本地用量 |
| `status` | 数据库、来源状态、未定价和同步信息 |

```sh
tokentick sync --database .build/audit/usage.sqlite --scope all
tokentick usage --database .build/audit/usage.sqlite --group day --json
tokentick records --database .build/audit/usage.sqlite --limit 100

tokentick usage --group thread --project Chat --timezone Asia/Shanghai \
  --from 2026-09-01 --through 2026-09-10 --sort amount --limit 100 --json
```

`usage` 与 `records` 支持日期、账号、任务、项目、模型、搜索、排序及分页，具体参数见 `--help`。日期范围包含首尾两天，不同条件取交集；`--unknown-account` 等参数明确筛选未知归属。项目 `Chat` 表示“无项目聊天”。

JSON 保留整数 tokens、纳美元金额、十进制单价、NULL 和统计时区。`records` 的 granularity 为 `usage_event`，包含 responseID、turnID、sourceOrdinal、UTC hour／minute；记录数不保证等同于网络请求数。界面 tokens 使用 K／M／B／T 并保留精确值。

查询用量和历史窗口不触发网络；`api-usage`、`current-limits` 和 API 同步会通过已登录 Codex 的 app-server 获取数据，可用 `--codex-bin` 指定 Codex 可执行文件。账号、日桶时区未完全确认的差额只作参考，不计金额或加入本地总量。

## 打包

```sh
./script/package_release.sh
```

脚本构建 arm64 Release App／CLI，执行 ad-hoc 签名及验证，生成 `.build/releases/local-*/TokenTick-*-local-*.zip` 和 SHA-256 文件。不使用付费 Developer Program、不提交 Apple 公证，也不自动安装或发布 GitHub Release。

同时生成仅包含 App 的 `TokenTick-<版本>.zip`，供首次下载安装和 Sparkle 更新使用。Sparkle 框架及辅助进程会按从内到外的顺序签名；ad-hoc 签名没有 Team ID，App 使用 `disable-library-validation` entitlement 载入动态框架，更新包使用独立的 Ed25519 签名校验。

包内安装说明从下节生成；另附 `BUILD.txt`、签名信息和依赖许可证。`BUILD.txt` 记录提交、是否存在未提交修改、工具链和架构。

## 发布与自动更新

App 使用与 Shuttle 相同的 Sparkle 2.9.6，默认每小时检查一次更新，可在“设置 → 关于”关闭自动检查，也可从应用菜单或关于页手动检查。发现新版本后显示发布说明，并由 Sparkle 下载、校验、替换 App 和重新启动。

更新源为公开仓库的 [appcast.xml](https://github.com/yeliex/tokentick/releases/latest/download/appcast.xml)。没有发布首个包含 appcast 的 Release 前，该地址不可用；首次接入 Sparkle 的版本仍需手动安装。自动更新仅覆盖 App，独立安装的 CLI 需手动替换。

推送 `vMAJOR.MINOR.PATCH` 标签会触发 `.github/workflows/release.yml`，在 macOS 26 上构建，生成发布说明和签名 appcast，并发布为 GitHub 最新 Release。版本显示来自标签，Sparkle 用于比较版本的 `CFBundleVersion` 来自递增的 `GITHUB_RUN_NUMBER`；迁移工作流时必须保证构建号大于已有发布。

发布需要仓库 Actions Secret `SPARKLE_PRIVATE_KEY` 与 `Info.plist` 中的 `SUPublicEDKey` 对应。本机签名私钥保存在钥匙串账户 `tokentick`，不要提交或打印私钥，也不要为每次发布重新生成密钥。

本地可生成签名更新产物而不发布：

```sh
./script/package_release.sh 0.1.1 3
# 使用上一步输出的 App 更新 ZIP 路径，输出目录必须尚不存在。
./script/generate_appcast.sh <App更新ZIP> <发布说明.md> .build/appcast
```

持续集成通过 `TOKENTICK_SPARKLE_PRIVATE_KEY` 标准输入签名；本地默认读取钥匙串账户 `tokentick`。更新包签名和 macOS 代码签名是两套独立校验，不需要付费开发者账号。

## 安装

TokenTick 仅支持 macOS 26.0+、Apple Silicon。App 与 CLI 使用 ad-hoc 签名，不依赖付费开发者账号或 Apple 公证。

### App

解压 ZIP，将 `TokenTick.app` 放入个人 `~/Applications` 或 `/Applications`，再打开。接入自动更新的版本可通过“检查更新…”升级；旧版本或手动升级时先退出旧实例，再替换 App。当前仍处于开发阶段：数据库结构兼容时继续使用，结构变化时直接重建并重新扫描源日志，不维护历史迁移链，也不自动备份大数据库。

首次从浏览器下载后，macOS 可能阻止打开。确认包的来源和校验值后，先尝试打开 App，再到“系统设置 → 隐私与安全性”选择“仍要打开”，遵循系统提示。参考 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。CLI 首次执行可能需要单独确认；安装步骤不关闭 Gatekeeper 或自动清除隔离属性。

### CLI

可直接运行解压目录中的 `bin/tokentick --help`，不需要 App 保持运行。必须同时保留 `TokenTick_TokenTickCore.bundle` 价格资源包。

在解压后的包目录执行以下命令安装到个人目录；这会替换该位置已有的 CLI 和资源包：

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 bin/tokentick "$HOME/.local/bin/tokentick"
ditto bin/TokenTick_TokenTickCore.bundle "$HOME/.local/bin/TokenTick_TokenTickCore.bundle"
"$HOME/.local/bin/tokentick" --help
```

需要直接输入 `tokentick` 时，自行把 `$HOME/.local/bin` 加入 PATH，不需要 sudo。

### 数据与完整性

App／CLI 默认共用 `~/Library/Application Support/TokenTick/usage.sqlite`，从进程 `CODEX_HOME`（默认 `~/.codex`）只读采集。App 运行期间自动同步，统计时区跟随系统；可在设置中开启开机启动。卸载 App／CLI 不删除统计数据库。

在 ZIP 和校验文件所在目录执行 `shasum -a 256 -c <文件名>.sha256` 核对完整性。完整 App／CLI 分发包中的 `BUILD.txt` 记录源码和构建状态，`Licenses` 包含 GRDB、Zstandard 和 Sparkle 许可证。金额为公开模型价格估算；API 每日参考差额不参与金额或本地用量统计。
