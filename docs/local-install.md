# TokenTick 安装说明

此包用于本地构建和安装验证，要求 macOS 26 或更新版本。仅支持 Apple Silicon，App 与 CLI 均只包含 arm64。

App、CLI 和嵌套资源包固定使用 ad-hoc 签名，无需付费 Apple Developer Program、签名证书或开发者团队。`BUILD.txt` 记录 `signing=ad-hoc`、`notarized=false`，App 与 CLI 的签名明细分别保存在 `App-signature.txt` 和 `CLI-signature.txt`。这与 Shuttle 的直接分发方式一致，未公证不作为发布阻塞条件。

## App

解压后可直接打开 `TokenTick.app`；长期使用时，退出已运行的 TokenTick，再将其放入个人 `~/Applications` 目录。升级时替换 App，不删除数据库。首次启动会自动采集本机 Codex 日志；验证专用数据可通过 `TOKENTICK_DATABASE` 和 `TOKENTICK_AUTOSYNC=0` 隔离。

### 首次下载后打开

通过浏览器下载的包可能被 macOS 阻止打开。确认来自 TokenTick 仓库的发布包后，先尝试打开 App，再进入“系统设置 → 隐私与安全性”，选择“仍要打开”并确认。流程见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。受管理的 Mac 可能限制此操作，需要遵循设备管理员的策略。

CLI 是独立可执行文件，下载后的首次执行也可能需要单独确认；App 的确认不代表 CLI 自动获准。安装脚本不会关闭 Gatekeeper 或清除隔离属性。若提示文件损坏，应先重新下载并核对校验值。

## CLI

可以直接执行解压目录中的 `bin/tokentick --help`。CLI 不需要 App 保持运行；必须随同保留 `TokenTick_TokenTickCore.bundle` 价格资源包。

在解压目录中执行以下命令，可安装到个人目录；命令会替换该位置已有的 `tokentick`：

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 bin/tokentick "$HOME/.local/bin/tokentick"
ditto bin/TokenTick_TokenTickCore.bundle "$HOME/.local/bin/TokenTick_TokenTickCore.bundle"
"$HOME/.local/bin/tokentick" --help
```

需要直接输入 `tokentick` 时，将 `$HOME/.local/bin` 加入自己的 shell PATH。升级 CLI 使用同一安装命令；不自动编辑 shell 配置，不要求 sudo。

## 数据与验证

App 与 CLI 默认共用 `~/Library/Application Support/TokenTick/usage.sqlite`。卸载可删除 App 和 CLI，统计数据库与迁移备份保留；只有明确不再需要历史数据时再单独处理数据目录。

`BUILD.txt` 记录源提交、源码是否有未提交修改、构建工具链、架构和签名状态。ZIP 旁的 `.sha256` 文件可在同目录通过 `shasum -a 256 -c <文件名>.sha256` 检查完整性；校验值不替代发布者身份验证。

`Licenses` 包含静态链接的 GRDB 与 Zstandard 许可证。模型换算金额是 API 等值估算，不是订阅账单；服务端日用量目前单独保存，跨设备差额尚未启用。
