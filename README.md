# TokenTick

Codex 用量与成本统计，专为 macOS 开发。

TokenTick 从本地 Codex 日志采集统计数据，记录每个任务、每天、每个项目和每个模型的 token 用量，并按历史模型价格换算美元金额。服务端每日总量与额度周期单独记录，跨设备差额仍待口径核实。

## 项目状态

已建立面向 **macOS 26.0+** 的原生 Xcode 工程，包含 SwiftUI App 和共享 Core 源码的 CLI。已实现本地 JSONL／Zstandard 增量采集、迁移、任务名称缓存、历史计价、服务端日桶／额度观测、统计缓存及共享同步流程。SwiftUI 已接入总览、每日趋势与表格、任务／项目分页、汇总检查器、请求级分页与证据、额度和数据状态；搜索、排序、交叉筛选等交互仍在完善。API 差额口径、长任务断点恢复及正式发布验收尚未完成。

- [需求与技术方案](docs/requirements.md)
- [实现计划](docs/implementation-plan.md)
- [客户端 UI 方案](docs/client-ui.md)
- [验收状态与剩余条件](docs/acceptance-status.md)

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
.build/DerivedData/Build/Products/Debug/tokentick sync \
  --database .build/audit/usage.sqlite --scope all
.build/DerivedData/Build/Products/Debug/tokentick scan \
  --database .build/audit/usage.sqlite --json
.build/DerivedData/Build/Products/Debug/tokentick usage \
  --database .build/audit/usage.sqlite --group day --json
.build/DerivedData/Build/Products/Debug/tokentick status \
  --database .build/audit/usage.sqlite
```

`sync --scope all|local|prices|api` 与 App 使用相同流程，保存最近同步报告，各来源失败互不清空已有数据。价格成功同步后仅重算本次价格日期及之后的记录；手动 `reprice` 仍可重算全部历史。App 启动时自动同步一次，可从工具栏或数据状态页重试；定时刷新与文件变动提示仍待接入。开发验证可用 `TOKENTICK_DATABASE` 指定独立数据库，`TOKENTICK_AUTOSYNC=0` 关闭本次启动自动同步，不改变持久设置。

也可省略 `--codex-home`，默认读取环境变量 `CODEX_HOME` 或 `~/.codex`。省略 `--database` 时使用 `~/Library/Application Support/TokenTick/usage.sqlite`。`scan` 只读 Codex 数据，写入 TokenTick 自己的数据库；存在解析问题时返回 1，参数错误返回 2。统计时区默认采用数据库首次初始化／升级时的系统时区并保存，价格日期始终使用 UTC。

统计缓存与范围查询：

```sh
.build/DerivedData/Build/Products/Debug/tokentick rebuild --database .build/audit/usage.sqlite --timezone Asia/Shanghai
.build/DerivedData/Build/Products/Debug/tokentick usage --database .build/audit/usage.sqlite \
  --group project --timezone Asia/Shanghai --from 2026-09-01 --through 2026-09-09 --limit 50 --offset 0 --json
```

`--group` 支持 `total|day|thread|project|model`，日期范围包含首尾两天；`--account <ID>` 与 `--unknown-account` 用于账号筛选。临时指定时区不会改变 App 的默认时区。缓存失效时自动重建；扫描者持锁时，已有连接直接查询已提交事实。只有日日期而无精确时间的数据，在不能换算的时区归到未知日期；范围查询排除它，并单独返回 `unknownDateTokens`。JSON 中 `records` 是统计记录数，API 日差额记录不被称为实际请求。`status` 显示缓存版本、时区和来源状态。

请求级明细与证据：

```sh
.build/DerivedData/Build/Products/Debug/tokentick records --database .build/audit/usage.sqlite \
  --day 2026-09-09 --timezone Asia/Shanghai --limit 100 --offset 0
```

`records` 与 App 检查器共用查询，默认按发生时间降序、记录 ID 降序分页，返回 `hasMore`。支持日期／账号条件，以及任务、项目、模型、单日的组合条件；未知归属使用 `--unknown-thread`、`--unknown-project`、`--unknown-model` 或 `--unknown-date`，不会与名称恰好为 `unknown` 的项目混淆。输出包含 Fast／长上下文、分项 tokens、实际十进制费率字符串、纳美元金额、最新任务名称与项目，以及统计证据和最近扫描位置。未知字段在 JSON 中显式为 `null`；`statisticalDate` 是所选时区日期，`usageDate` 是计价 UTC 日期。查询不会重建统计缓存或读取对话正文。

组合筛选与排序（`usage` 和 `records` 共用）：

```sh
.build/DerivedData/Build/Products/Debug/tokentick usage --group thread \
  --project TokenTick --model gpt-5.6-sol --from 2026-09-01 --through 2026-09-09 \
  --search "统计" --sort amount --limit 100 --json
```

不同归属条件取交集，同一维度不允许重复指定。标题／ID 搜索按普通文本匹配，不区分大小写与音调符号，`%`、`_` 不作为通配符。`--sort automatic|tokens|amount|name` 在分页前排序；默认日汇总按日期降序，其余汇总按 tokens 降序，明细按发生时间降序。相同排序值使用分组键或记录 ID 保持顺序稳定。两种查询均返回 `hasMore`；金额排序使用已知分项金额，不代表缺价记录的完整成本。交叉筛选直接查询 SQLite 事实，普通维度汇总继续使用统计缓存，不持久化所有筛选组合。

App 默认在运行期间自动同步：文件变化合并后采集，每分钟核对本地文件，每五分钟刷新远端统计，价格每日成功获取一次。设置中可关闭；取消当前同步后至少 60 秒不自动重启。休眠恢复后补扫，退出 App 后停止，不安装后台 daemon。`TOKENTICK_AUTOSYNC=0` 仍可用于隔离运行验证。

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

`limits` 支持 `--from`／`--through`（含首尾日期）、`--timezone`、`--account`、`--limit-id`、`--window primary|secondary` 与 `--limit`／`--offset` 分页；返回 `hasMore`。日期匹配与所选本地日期范围重叠的窗口，不拆分或按比例分配周期用量。`--latest` 仅查询每个账号最近一次观测中存在的窗口，不代表此刻仍有效，也不恢复最近快照中缺失的旧窗口。每行包含已保存的来源 JSON，缺失的 tokens 和分项金额显式输出 `null`。

`sync-api` 启动短期 Codex app-server，通过 stdio 读取统计；需要本机安装且已登录的 Codex CLI，可用 `--codex-bin` 指定其路径。TokenTick 不读取或复制认证文件，认证由 Codex 自己管理。日桶保存原始日期和整数 tokens；目前账号归属、日边界和 token 可比口径尚未确认，服务端总量单独显示，不与本地相加。额度百分比为最后观测值，周期 tokens／金额缺乏归属证据时保持 NULL。查询不会触发联网或创建常驻进程。

两个 scheme 都以 macOS 26.0 为最低版本。App 本地开发使用 ad-hoc 签名，不要求开发者团队；Developer ID 签名可在打包时显式启用，公证尚未完成，CLI 本地安装方式见下文。Core 由本地 Swift Package 的 TokenTickCore 模块编译，新增 Core 文件自动进入模块；`TokenTickApp.swift` 与 `cli.swift` 分别只加入对应 Xcode target。

## 本地 Release 打包

```sh
./script/package_release.sh
```

脚本构建 arm64／x86_64 的 App 和 CLI，在最终组装后完成 ad-hoc 签名及验证，生成 `.build/releases/local-*/TokenTick-*-local-*.zip` 和 SHA-256 校验文件。包内包括安装说明、依赖许可证、源码提交和工具链信息；每次使用独立目录，不覆盖已有验证包，不安装到系统目录或发布 GitHub Release。

CLI 可直接运行，也可按[本地安装说明](docs/local-install.md)安装到个人 `~/.local/bin`。默认生成的 ad-hoc 包未经过 Developer ID 签名、公证或 macOS 26 真机验收，不作为正式分发版本。

本机已安装有效的 Developer ID Application 证书时，可显式指定完整证书名称：

```sh
./script/package_release.sh --sign 'Developer ID Application: 姓名 (TEAMID)'
```

此方式生成 `.build/releases/signed-*` 下的签名包，为 App、CLI 和嵌套 GRDB 资源包签署安全时间戳；App 与 CLI 启用 hardened runtime。包内 `BUILD.txt` 记录 `signing=developer-id`，另附两份签名明细。脚本不保存私钥或认证凭据，不自动提交公证；`notarized=false` 时仍不能视为通过 Gatekeeper 的正式分发包。

已完成的本地签名、解压安装、真实界面与性能基线见 [Release 验证记录](docs/release-validation.md)。

## 外观验证

Debug App 支持进程环境变量 `TOKENTICK_APPEARANCE=light|dark`，只覆盖当前进程的原生外观；不设置时跟随系统，不改写用户偏好，Release 构建不包含这个入口。先退出已有测试实例，再运行：

```sh
open -n --env TOKENTICK_APPEARANCE=light --env TOKENTICK_AUTOSYNC=0 \
  .build/DerivedData/Build/Products/Debug/TokenTick.app
```

验证后退出该实例，正常打开 App 即恢复跟随系统及原有自动同步设置。

## 数据层测试

```sh
swift test
```

通过 `swift package add-dependency` 与 `swift package add-target-dependency` 管理外部依赖，并提交生成的 `Package.resolved`。Core 与测试的包管理入口是根目录 `Package.swift`，App 仍通过 Xcode 工程构建。
