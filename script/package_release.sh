#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "用法：$0（生成本地 Release 验证包，不签发正式版本）" >&2
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
    -derivedDataPath "$BUILD_DIR" ONLY_ACTIVE_ARCH=NO \
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
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$PACKAGE_DIR/TokenTick.app"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$CLI_EXECUTABLE"
/usr/bin/codesign --verify --deep --strict "$PACKAGE_DIR/TokenTick.app"
/usr/bin/codesign --verify --strict "$CLI_EXECUTABLE"
for ARCH in arm64 x86_64; do
  /usr/bin/lipo "$APP_EXECUTABLE" -verify_arch "$ARCH"
  /usr/bin/lipo "$CLI_EXECUTABLE" -verify_arch "$ARCH"
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
echo "本地验证包：$ARCHIVE"
echo "校验文件：$ARCHIVE.sha256"
echo "此产物为 ad-hoc 签名，未经过 Developer ID 签名、公证或 macOS 26 真机验收。"
