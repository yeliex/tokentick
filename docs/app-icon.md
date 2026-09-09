# 系统级应用图标

核对日期：2026-09-10。App 当前仍使用已定稿的浅色 ICNS；内容区明暗品牌图和菜单模板已接入。下述 `.icon` 仅为隔离验证，尚未替换产品资源，也未完成 Dock／Finder 验收。

## 原生方案与既有设计

macOS 26 的系统级多外观图标采用 Icon Composer `.icon` 文件，由 Xcode 编译为图标资源。App target 的 `ASSETCATALOG_COMPILER_APPICON_NAME` 与文件名一致，编译器生成 `CFBundleIconName` 和对应 ICNS。不能把内容区 `BrandIcon.imageset` 的明暗选择当作系统图标切换已经完成。

Apple 建议在导出图层时移除画布遮罩，将背景与图形分离，系统负责外形裁切。TokenTick 保留「用量环 · 分格」的轮廓和已定稿的暖白琥珀／石墨薄荷配色；后续原生资源应让背景、主体环和琥珀／薄荷分格分别承担可调整的颜色层，不重新设计标记。系统图标外观选择由系统负责，不能仅在 App 运行时更换 Dock 图片来代替 Finder 和未运行状态的资源支持。

来源：[Apple Icon Composer 文档](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)、[官方 Landmarks 示例](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass)、[Asset Catalog 图标说明](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)。文档与示例留存在 `.build/research/icon-composer/`，示例代码仅用于核对资源结构，没有复制进产品。

## 本次编译与视觉结果

在 Xcode 27 beta／macOS 27 上，以 `--platform macosx --minimum-deployment-target 26.0` 编译隔离的 `TokenTick.icon`。直接复用现有 `app-light.png` 和 `app-dark.png`，源图片逐字节相同，关闭图层玻璃效果与额外阴影，通过 `image-name-specializations` 选择深色图片。

编译成功，`assetutil --info` 确认：

| 外观 | 实际引用 |
| --- | --- |
| `NSAppearanceNameAqua` | `TokenTick_Assets/app-light` |
| `NSAppearanceNameDarkAqua` | `TokenTick_Assets/app-dark` |

编译器生成 `Assets.car` 和 `TokenTick.icns`，Info plist 的 `CFBundleIconName`／`CFBundleIconFile` 均为 `TokenTick`。这证明资源变体能被编译和区分，不能证明系统运行时已验收。

导出的 256px 默认图标出现额外浅色外框及重复圆角：原图已带边距与圆角底板，作为整张前景叠入系统图标后产生不合适的嵌套。该方案未通过视觉检查，因此没有加入 Xcode 工程，也没有修改现有图标或应用行为。后续应按原设计拆分背景与标记后重新预览，不能仅以编译成功作为图标接入完成的证据。

两个试验限制也已确认：`supported-platforms.squares` 的 `macOS` 字符串被编译器拒绝，使用官方示例中的 `shared` 编码后成功；本机 `ictool` 不接受尝试的 `--help`／`--usage`，最终使用 Xcode 现有构建命令中的 `actool` 参数完成隔离编译，没有引入产品运行时私有 API。

本机证据：`.build/research/icon-composer/verification.json`、`compile.log`、`compiled-info.plist`、`catalog-info.json` 和 `compiled.iconset/icon_128x128@2x.png`。这些仅是开发验证产物，不进入分发包。

## 剩余验收

1. 在 Icon Composer 中按原设计准备分层资源，核对浅色、深色及小尺寸下的轮廓、颜色和边距，消除重复外框。
2. 加入 App target，移除旧的显式浅色图标配置，确认生成 Info plist、编译目录及包签名；检查实际引用，而非仅检查文件是否存在。
3. 在系统中检查 Dock 和 Finder 的浅深外观、App 启动／退出后的图标及各常用尺寸。系统选择其他图标样式时尊重系统偏好。
4. macOS 26 真机另行验收。本机 macOS 27 的编译与导出不能替代最低系统运行验证。

本次 Computer Use 返回 Mac 锁定，Icon Composer 原生配置和系统交互检查仍需用户手动解锁后继续；已有解锁请求待响应。
