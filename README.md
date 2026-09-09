# TokenTick

Codex 用量与成本统计，专为 macOS 开发。

TokenTick 从本地 Codex 日志采集统计数据，记录每个任务、每天、每个项目和每个模型的 token 用量，并按历史模型价格换算美元金额。服务端每日总量用于补充未归属用量，额度周期单独记录。

## 项目状态

已建立面向 **macOS 26.0+** 的原生 Xcode 工程，包含 SwiftUI App 和共享 Core 源码的 CLI。当前提供窗口／菜单栏骨架、现有图标、CLI 帮助／版本命令，以及 GRDB 存储与迁移基础；日志采集、计价与真实统计仍按计划实现。

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

两个 scheme 都以 macOS 26.0 为最低版本。App 使用本地 ad-hoc 签名，不要求开发者团队；正式分发签名、公证和 CLI 安装在发布阶段实现。Core 由本地 Swift Package 的 TokenTickCore 模块编译，新增 Core 文件自动进入模块；`TokenTickApp.swift` 与 `cli.swift` 分别只加入对应 Xcode target。

数据层测试：

```sh
swift test
```

通过 `swift package add-dependency` 与 `swift package add-target-dependency` 管理外部依赖，并提交生成的 `Package.resolved`。Core 与测试的包管理入口是根目录 `Package.swift`，App 仍通过 Xcode 工程构建。
