#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "用法：$0（固定使用 ad-hoc 签名，无需开发者账号或证书）" >&2
  exit 2
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/ReleaseDerivedData"
LOG_DIR="$PROJECT_ROOT/.build/logs"
RELEASE_DIR="$PROJECT_ROOT/.build/releases"
mkdir -p "$LOG_DIR" "$RELEASE_DIR"

for SCHEME in TokenTick tokentick; do
  BUILD_LOG="$LOG_DIR/release-$SCHEME-build.log"
  if xcodebuild -project "$PROJECT_ROOT/TokenTick.xcodeproj" -scheme "$SCHEME" \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD_DIR" ARCHS=arm64 \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build >"$BUILD_LOG" 2>&1; then
    echo "$SCHEME Release 构建成功。"
  else
    awk '/error:|BUILD FAILED|failed:/ && count++ < 30 { print substr($0, 1, 1000) }' "$BUILD_LOG" >&2
    echo "完整构建日志：$BUILD_LOG" >&2
    exit 1
  fi
done

PRODUCTS="$BUILD_DIR/Build/Products/Release"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PRODUCTS/TokenTick.app/Contents/Info.plist")"
SOURCE_REVISION="$(git -C "$PROJECT_ROOT" rev-parse --short=12 HEAD)"
# 每次使用独立目录，失败时不覆盖上一份已经核验的产物。
STAGING="$(mktemp -d "$RELEASE_DIR/local-XXXXXX")"
PACKAGE_NAME="TokenTick-$VERSION-local-$SOURCE_REVISION"
PACKAGE_DIR="$STAGING/$PACKAGE_NAME"
mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/Licenses"
/usr/bin/ditto "$PRODUCTS/TokenTick.app" "$PACKAGE_DIR/TokenTick.app"
/usr/bin/ditto "$PRODUCTS/tokentick" "$PACKAGE_DIR/bin/tokentick"
cp "$PROJECT_ROOT/docs/local-install.md" "$PACKAGE_DIR/README.md"
cp "$BUILD_DIR/SourcePackages/checkouts/GRDB.swift/LICENSE" "$PACKAGE_DIR/Licenses/GRDB.txt"
cp "$BUILD_DIR/SourcePackages/checkouts/zstd/LICENSE" "$PACKAGE_DIR/Licenses/Zstandard.txt"

APP_EXECUTABLE="$PACKAGE_DIR/TokenTick.app/Contents/MacOS/TokenTick"
CLI_EXECUTABLE="$PACKAGE_DIR/bin/tokentick"
# CLI 构建可能更新共享资源包的签名；最终组装后再封印 App 的资源。
/usr/bin/codesign --force --sign - --timestamp=none "$PACKAGE_DIR/TokenTick.app/Contents/Resources/GRDB_GRDB.bundle"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$PACKAGE_DIR/TokenTick.app"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$CLI_EXECUTABLE"
/usr/bin/codesign --verify --deep --strict "$PACKAGE_DIR/TokenTick.app"
/usr/bin/codesign --verify --strict "$CLI_EXECUTABLE"
/usr/bin/codesign -dvvv "$PACKAGE_DIR/TokenTick.app" >"$PACKAGE_DIR/App-signature.txt" 2>&1
/usr/bin/codesign -dvvv "$CLI_EXECUTABLE" >"$PACKAGE_DIR/CLI-signature.txt" 2>&1
for EXECUTABLE in "$APP_EXECUTABLE" "$CLI_EXECUTABLE"; do
  [ "$(/usr/bin/lipo -archs "$EXECUTABLE")" = "arm64" ] || { echo "产物必须仅包含 arm64。" >&2; exit 1; }
done
"$CLI_EXECUTABLE" --help >"$LOG_DIR/release-cli-help.log"

{
  echo "configuration=Release"
  echo "signing=ad-hoc"
  echo "notarized=false"
  echo "source_commit=$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]; then
    echo "source_dirty=true"
  else
    echo "source_dirty=false"
  fi
  echo "minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PACKAGE_DIR/TokenTick.app/Contents/Info.plist")"
  echo "app_architectures=$(/usr/bin/lipo -archs "$APP_EXECUTABLE")"
  echo "cli_architectures=$(/usr/bin/lipo -archs "$CLI_EXECUTABLE")"
  /usr/bin/xcodebuild -version
} >"$PACKAGE_DIR/BUILD.txt"

ARCHIVE="$STAGING/$PACKAGE_NAME.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$ARCHIVE"
(cd "$STAGING" && /usr/bin/shasum -a 256 "$PACKAGE_NAME.zip" >"$PACKAGE_NAME.zip.sha256")
echo "Release 验证包：$ARCHIVE"
echo "校验文件：$ARCHIVE.sha256"
echo "签名方式：ad-hoc，无需付费开发者账号，不提交公证。首次下载后的打开方式见包内 README.md；macOS 26 真机另行验收。"
