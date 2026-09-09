# TokenTick 图标资源

定稿采用「起始色收敛」版本：浅色为暖白琥珀，深色为石墨薄荷。直接打开 [预览页](index.html) 可查看效果。

## 应用图标

`default/` 内的 `app-light` 和 `app-dark` 各提供 SVG 源文件、1024 × 1024 PNG 与 macOS ICNS。`mark-light.svg`、`mark-dark.svg` 为无底板的彩色标记。

渐变从左上到右下，中间色位于 52%。Light：`#F8F1E5 → #F1E6D4 → #D8C7A8`；Dark：`#40564E → #2D4039 → #15231F`。

## 菜单栏

`menubar/template.svg` 为单色矢量源文件；`template-18.png`、`template-18@2x.png` 分别为 18pt 的 1x、2x 透明底模板。

接入时将 NSImage 标记为 `isTemplate = true`，由系统着色，无需单独的白色资源。应用图标的浅深外观尚未接入原生切换。
