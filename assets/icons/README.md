# TokenTick icon assets

The app uses a segmented usage ring: warm white and amber in light mode, graphite and mint in dark mode. Open the [preview](index.html) to inspect the artwork.

## App icon

`default/` contains SVG sources, 1024 × 1024 PNGs, and macOS ICNS files for `app-light` and `app-dark`. `mark-light.svg` and `mark-dark.svg` contain the colored mark without a background.

The background gradient runs from top left to bottom right with its middle stop at 52%:

- Light: `#F8F1E5 → #F1E6D4 → #D8C7A8`
- Dark: `#40564E → #2D4039 → #15231F`

The app uses [TokenTick.icon](../../TokenTick/Resources/TokenTick.icon). Its light and dark PNG assets match the approved PNG sources here. The native layer scale is `1024 / 928` to compensate for transparent padding; the system supplies the outer shape and appearance selection.

When changing artwork, update the source assets, in-app brand images, and `.icon/Assets` together. Verify PNG consistency, exported appearance, and the light/dark references in the built app.

## Menu bar

`menubar/template.svg` is the monochrome vector source. `template-18.png` and `template-18@2x.png` are transparent 1x and 2x templates at 18 pt.

Mark the image as `isTemplate = true` so macOS controls its color. The app can overlay a current-limit number using cached template images. A separate white template is unnecessary.

In-app branding uses Asset Catalog appearance variants. Icon Composer compiles the system icon's light and dark assets; the app does not replace the Dock icon at runtime.
