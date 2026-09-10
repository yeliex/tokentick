# 系统级应用图标

核对日期：2026-09-10。App 已接入 `TokenTick/Resources/TokenTick.icon`，由 Xcode 编译系统级明暗图标。Debug／通用 Release 构建、包内资源及导出预览已验证；Dock／Finder 的实际切换和 macOS 26 真机仍待验收。

## 资源与布局

`.icon/Assets` 直接保存已定稿的 `app-light.png` 和 `app-dark.png`，与 `assets/icons/default/` 中的原图逐字节相同。`image-name-specializations` 为默认外观选择浅色图，为 dark 选择深色图。原有标记、三段渐变、52% 中间色位置和 SVG／PNG／ICNS 原始资源均未修改。

原图是 1024px 画布，底板从 48px 延伸至 976px，实际宽度为 928px。图层布局使用 `1024 / 928`，即约 `1.103448275862069` 的等比缩放，并保持居中，将透明边距移出系统图标的有效裁切范围。背景为透明，关闭图层玻璃效果、额外阴影和半透明处理；系统继续负责自己的外框、尺寸与外观渲染。

最初不带布局调整的原型出现额外浅色外框和重复圆角。后续导出确认，补偿现有透明边距即可消除该问题，背景分层并非必要条件。原生线性渐变仅支持两个颜色，而原设计使用三个停止点；保留原图能避免为迁就背景配置改变定稿渐变。

内容区仍使用 `BrandIcon.imageset` 的明暗图片，菜单栏仍为单色模板。没有加入运行时更换 Dock 图标的代码。

## Xcode 接入

- App target 将 `.icon` 作为 `folder.iconcomposer.icon` 资源参与编译；Debug 和 Release 的 `ASSETCATALOG_COMPILER_APPICON_NAME` 均为 `TokenTick`。
- 移除旧的显式 `CFBundleIconFile=app-light`，由编译器生成 `CFBundleIconName=TokenTick` 和 `CFBundleIconFile=TokenTick`。
- 编译后的 `Assets.car` 包含分别引用 `TokenTick_Assets/app-light` 和 `TokenTick_Assets/app-dark` 的 Aqua／DarkAqua 图标组，以及对应图标栈；产品中存在 `TokenTick.icns`，旧 `app-light.icns` 已不再打包。
- `.icon` 内使用官方示例的 `supported-platforms.squares=shared` 编码；App 的实际编译平台与最低系统仍为 macOS／26.0，不增加其他平台 target。

来源：[Apple Icon Composer 文档](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)、[官方 Landmarks 示例](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass)、[Asset Catalog 图标说明](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)。示例只用于核对资源结构，没有复制进产品。

## 验证与复现

本机为 Xcode 27 beta／macOS 27。Icon Composer 自带的 `ictool` 可在不操作编辑器界面的情况下导出预览；它与 `xcrun ictool` 是不同入口，后者不接受 `--export-image`。例如，从仓库根目录执行：

```sh
ICON_TOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
"$ICON_TOOL" TokenTick/Resources/TokenTick.icon --export-image \
  --output-file /tmp/tokentick-light-26.png --platform macOS --rendition Default \
  --width 256 --height 256 --scale 1 --design-generation 26
```

将 `--rendition` 改为 `Dark` 可导出深色预览。本次分别检查了 26／27 渲染代际、Default／Dark、32px／256px 的八张导出图，均保留可辨认的环形与分格，没有此前原型的额外底板。它们是渲染器预览，不能当作对应真实系统已运行的证据。

Debug 和通用 Release 构建成功，分别核对生成的 Info plist、Aqua／DarkAqua 图标组、最低系统和 `codesign --verify --deep --strict`。本次只变更图标资源与工程配置，不修改 Core、数据库或数据采集行为。

证据位于 `.build/research/icon-composer/app-verification.json`、`app-debug-catalog.json`、`app-release-catalog.json` 和 `app-<default|dark>-<26|27>-<32|256>.png`；构建日志为 `.build/logs/native-icon-app-build.log`、`.build/logs/native-icon-release-build.log`。原型及官方资料也保留在该研究目录，不进入分发包。

历史验证（当前已改为 ad-hoc 分发）：干净提交 `b8aa16dd19cc` 曾经 `script/package_release.sh --sign 'Developer ID Application: Yexin Wang (47YTFN9LPP)'` 生成通用签名验证包：`.build/releases/signed-3EeOjY/TokenTick-0.1.0-signed-b8aa16dd19cc.zip`。App／CLI 签名与双架构检查通过；ZIP SHA-256、包内图标资源字节、Info plist、CLI 在 `/tmp` 下使用独立空库启动和 v4 schema 均已核对，证据为同目录 `verification.json`。该包尚未公证，不代表 Gatekeeper 或系统交互验收通过。

## 剩余验收

1. 在系统中检查 Dock 和 Finder 的浅深外观、App 启动／退出后的图标和常用尺寸，尊重系统图标样式偏好。
2. 在 macOS 26 真机完成同样检查，不能以 macOS 27 宿主机的 26 代际导出替代。
3. 后续更新图标时，同时更新原始定稿、内容区图片和 `.icon/Assets`，再核对原图一致性、导出和包内外观引用。

最近一次 Computer Use 返回 Mac 锁定，系统交互检查仍需用户手动解锁后继续；已有解锁请求待响应。
