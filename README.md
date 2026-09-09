# TokenTick

Codex 用量与成本统计，专为 macOS 开发。

TokenTick 从本地 Codex 日志采集统计数据，记录每个任务、每天、每个项目和每个模型的 token 用量，并按历史模型价格换算美元金额。服务端每日总量用于补充未归属用量，额度周期单独记录。

## 项目状态

已建立面向 **macOS 26.0+** 的原生 Xcode 工程，包含 SwiftUI App 和共享 Core 源码的 CLI。已实现窗口／菜单栏骨架、现有图标、GRDB 存储与迁移、本地 JSONL／Zstandard 增量采集、任务名称缓存、历史计价、服务端日桶／额度观测和统计缓存。CLI 支持多维度、时区、日期范围与分页查询；API 差额、整体同步和客户端数据绑定仍按计划实现。

- [需求与技术方案](docs/requirements.md)
- [实现计划](docs/implementation-plan.md)
- [客户端 UI 方案](docs/client-ui.md)

## 技术方向

- Swift 6 + SwiftUI 原生 macOS 26+ App。
- SQLite + GRDB 保存用量、价格历史和统计缓存。
- App 与 `tokentick` CLI 共用业务代码，通过不同 target 编译。
- 流式增量扫描本地日志，支持归档、fork、revert 和压缩文件。
- 界面采用 shadcn Luma 的视觉方向，参考 Shuttle 原生界面。

金额表示按公开模型价格计算的 API 等值金额，不等同于 ChatGPT 订阅实际账单。

## 图标资源

默认采用「起始色收敛」配色，浅色、深色与菜单栏资源已保存到 [assets/icons](assets/icons/README.md)。

## 本地开发

使用带 macOS 26 或更新 SDK 的 Xcode，打开 `TokenTick.xcodeproj`。当前在 Xcode 27 / macOS 27 上验证构建和进程启动，macOS 26 真机交互仍待验收。

运行 App：

```sh
./script/build_and_run.sh --verify
```

Codex 的 Run 按钮使用同一脚本。构建产物在 `.build/DerivedData`，日志在 `.build/logs/app-build.log`；脚本也支持 `--debug`、`--logs` 和 `--telemetry`。

构建并使用 CLI：

```sh
xcodebuild -project TokenTick.xcodeproj -scheme tokentick \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData build
.build/DerivedData/Build/Products/Debug/tokentick --help
```

采集和查询（首次运行建议指定独立数据库）：

```sh
.build/DerivedData/Build/Products/Debug/tokentick scan \
  --database .build/audit/usage.sqlite --json
.build/DerivedData/Build/Products/Debug/tokentick usage \
  --database .build/audit/usage.sqlite --group day --json
.build/DerivedData/Build/Products/Debug/tokentick status \
  --database .build/audit/usage.sqlite
```

也可省略 `--codex-home`，默认读取环境变量 `CODEX_HOME` 或 `~/.codex`。省略 `--database` 时使用 `~/Library/Application Support/TokenTick/usage.sqlite`。`scan` 只读 Codex 数据，写入 TokenTick 自己的数据库；存在解析问题时返回 1，参数错误返回 2。统计时区默认采用数据库首次初始化／升级时的系统时区并保存，价格日期始终使用 UTC。

统计缓存与范围查询：

```sh
.build/DerivedData/Build/Products/Debug/tokentick rebuild --database .build/audit/usage.sqlite --timezone Asia/Shanghai
.build/DerivedData/Build/Products/Debug/tokentick usage --database .build/audit/usage.sqlite \
  --group project --timezone Asia/Shanghai --from 2026-09-01 --through 2026-09-09 --limit 50 --offset 0 --json
```

`--group` 支持 `total|day|thread|project|model`，日期范围包含首尾两天；`--account <ID>` 与 `--unknown-account` 用于账号筛选。临时指定时区不会改变 App 的默认时区。缓存失效时自动重建；扫描者持锁时，已有连接直接查询已提交事实。只有日日期而无精确时间的数据，在不能换算的时区归到未知日期；范围查询排除它，并单独返回 `unknownDateTokens`。JSON 中 `records` 是统计记录数，API 日差额记录不被称为实际请求。`status` 显示缓存版本、时区和来源状态。

价格同步与重算：

```sh
.build/DerivedData/Build/Products/Debug/tokentick sync-prices --database .build/audit/usage.sqlite
.build/DerivedData/Build/Products/Debug/tokentick prices --database .build/audit/usage.sqlite
.build/DerivedData/Build/Products/Debug/tokentick reprice --database .build/audit/usage.sqlite
```

价格按 UTC 采集日保存，每天成功一次，只记录价格变化。新扫描的请求自动匹配已有历史价格；`reprice` 显式重算已有用量。首次采价以前的日期不会套用今日价格；模式、缓存分项或价格缺失时，保留可算分项，总金额仍为空。重算报告列出未定价原因。

服务端统计采集与离线查询：

```sh
.build/DerivedData/Build/Products/Debug/tokentick sync-api --database .build/audit/usage.sqlite
.build/DerivedData/Build/Products/Debug/tokentick api-usage --database .build/audit/usage.sqlite --limit 1000
.build/DerivedData/Build/Products/Debug/tokentick limits --database .build/audit/usage.sqlite
```

`sync-api` 启动短期 Codex app-server，通过 stdio 读取统计；需要本机安装且已登录的 Codex CLI，可用 `--codex-bin` 指定其路径。TokenTick 不读取或复制认证文件，认证由 Codex 自己管理。日桶保存原始日期和整数 tokens；目前账号归属、日边界和 token 可比口径尚未确认，服务端总量单独显示，不与本地相加。额度百分比为最后观测值，周期 tokens／金额缺乏归属证据时保持 NULL。查询不会触发联网或创建常驻进程。

两个 scheme 都以 macOS 26.0 为最低版本。App 使用本地 ad-hoc 签名，不要求开发者团队；正式分发签名、公证和 CLI 安装在发布阶段实现。Core 由本地 Swift Package 的 TokenTickCore 模块编译，新增 Core 文件自动进入模块；`TokenTickApp.swift` 与 `cli.swift` 分别只加入对应 Xcode target。

数据层测试：

```sh
swift test
```

通过 `swift package add-dependency` 与 `swift package add-target-dependency` 管理外部依赖，并提交生成的 `Package.resolved`。Core 与测试的包管理入口是根目录 `Package.swift`，App 仍通过 Xcode 工程构建。
