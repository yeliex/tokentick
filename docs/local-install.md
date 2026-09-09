# TokenTick 本地 Release 验证包

此包用于本地构建和安装验证，要求 macOS 26 或更新版本。App 与 CLI 均包含 arm64 和 x86_64；构建包含某架构不代表已经在对应设备运行验证。

当前使用 ad-hoc 签名，未经过 Developer ID 签名和 Apple 公证，不能作为已经通过 Gatekeeper 的正式下载版本。请在本机源码构建后验证，不通过关闭系统安全检查或删除隔离属性绕过分发验收。

## App

解压后可直接打开 `TokenTick.app`；长期使用时，退出已运行的 TokenTick，再将其放入个人 `~/Applications` 目录。升级时替换 App，不删除数据库。首次启动会自动采集本机 Codex 日志；验证专用数据可通过 `TOKENTICK_DATABASE` 和 `TOKENTICK_AUTOSYNC=0` 隔离。

## CLI

可以直接执行解压目录中的 `bin/tokentick --help`。CLI 不需要 App 保持运行。

在解压目录中执行以下命令，可安装到个人目录；命令会替换该位置已有的 `tokentick`：

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 bin/tokentick "$HOME/.local/bin/tokentick"
"$HOME/.local/bin/tokentick" --help
```

需要直接输入 `tokentick` 时，将 `$HOME/.local/bin` 加入自己的 shell PATH。升级 CLI 使用同一安装命令；不自动编辑 shell 配置，不要求 sudo。

## 数据与验证

App 与 CLI 默认共用 `~/Library/Application Support/TokenTick/usage.sqlite`。卸载可删除 App 和 CLI，统计数据库与迁移备份保留；只有明确不再需要历史数据时再单独处理数据目录。

`BUILD.txt` 记录源提交、源码是否有未提交修改、构建工具链、架构和签名状态。ZIP 旁的 `.sha256` 文件可在同目录通过 `shasum -a 256 -c <文件名>.sha256` 检查完整性；校验值不替代发布者身份验证。

`Licenses` 包含静态链接的 GRDB 与 Zstandard 许可证。模型换算金额是 API 等值估算，不是订阅账单；服务端日用量目前单独保存，跨设备差额尚未启用。
