# TokenTick

Codex 用量与成本统计，专为 macOS 开发。

TokenTick 从本地 Codex 日志采集统计数据，记录每个任务、每天、每个项目和每个模型的 token 用量，并按历史模型价格换算美元金额。服务端每日总量用于补充未归属用量，额度周期单独记录。

## 项目状态

目前处于需求与技术方案阶段，尚未实现可运行的 App 或 CLI。

详细范围、数据结构、采集与计价规则、迁移方案和验收标准见 [需求与技术方案](docs/requirements.md)。

## 技术方向

- Swift + SwiftUI 原生 macOS App。
- SQLite + GRDB 保存用量、价格历史和统计缓存。
- App 与 `tokentick` CLI 共用业务代码，通过不同 target 编译。
- 流式增量扫描本地日志，支持归档、fork、revert 和压缩文件。
- 界面采用 shadcn Luma 的视觉方向，参考 Shuttle 原生界面。

金额表示按公开模型价格计算的 API 等值金额，不等同于 ChatGPT 订阅实际账单。

## 图标资源

默认采用「起始色收敛」配色，浅色、深色与菜单栏资源已保存到 [assets/icons](assets/icons/README.md)。
