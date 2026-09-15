#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 0 ] && { [ "$#" -ne 2 ] || [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; }; then
  echo "Usage: $0 [version increasing-build-number] (ad-hoc signing)" >&2
  exit 2
fi
BUILD_SETTINGS=("CODE_SIGN_IDENTITY=-" "CODE_SIGN_STYLE=Manual")
if [ "$#" -eq 2 ]; then
  BUILD_SETTINGS+=("MARKETING_VERSION=$1" "CURRENT_PROJECT_VERSION=$2")
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
    "${BUILD_SETTINGS[@]}" build >"$BUILD_LOG" 2>&1; then
    echo "$SCHEME Release build succeeded."
  else
    awk '/error:|BUILD FAILED|failed:/ && count++ < 30 { print substr($0, 1, 1000) }' "$BUILD_LOG" >&2
    tail -n 60 "$BUILD_LOG" >&2
    echo "Full build log: $BUILD_LOG" >&2
    exit 1
  fi
done

PRODUCTS="$BUILD_DIR/Build/Products/Release"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PRODUCTS/TokenTick.app/Contents/Info.plist")"
SOURCE_REVISION="$(git -C "$PROJECT_ROOT" rev-parse --short=12 HEAD)"
# Use a fresh directory so a failed build cannot overwrite previously verified artifacts.
STAGING="$(mktemp -d "$RELEASE_DIR/local-XXXXXX")"
PACKAGE_NAME="TokenTick-$VERSION-local-$SOURCE_REVISION"
PACKAGE_DIR="$STAGING/$PACKAGE_NAME"
mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/Licenses"
/usr/bin/ditto "$PRODUCTS/TokenTick.app" "$PACKAGE_DIR/TokenTick.app"
/usr/bin/ditto "$PRODUCTS/tokentick" "$PACKAGE_DIR/bin/tokentick"
/usr/bin/ditto "$PRODUCTS/TokenTick_TokenTickCore.bundle" "$PACKAGE_DIR/bin/TokenTick_TokenTickCore.bundle"
# Extract the self-contained installation section from README to avoid duplicating instructions.
awk '/^## Installation$/ { active=1; print "# TokenTick installation"; next } active && /^## / { exit } active { print }' \
  "$PROJECT_ROOT/README.md" >"$PACKAGE_DIR/README.md"
cp "$BUILD_DIR/SourcePackages/checkouts/GRDB.swift/LICENSE" "$PACKAGE_DIR/Licenses/GRDB.txt"
cp "$BUILD_DIR/SourcePackages/checkouts/zstd/LICENSE" "$PACKAGE_DIR/Licenses/Zstandard.txt"
cp "$BUILD_DIR/SourcePackages/checkouts/Sparkle/LICENSE" "$PACKAGE_DIR/Licenses/Sparkle.txt"

APP_EXECUTABLE="$PACKAGE_DIR/TokenTick.app/Contents/MacOS/TokenTick"
CLI_EXECUTABLE="$PACKAGE_DIR/bin/tokentick"
# The CLI build may update shared resource signatures; seal app resources after final assembly.
/usr/bin/codesign --force --sign - --timestamp=none "$PACKAGE_DIR/TokenTick.app/Contents/Resources/GRDB_GRDB.bundle"
SPARKLE="$PACKAGE_DIR/TokenTick.app/Contents/Frameworks/Sparkle.framework"
for COMPONENT in "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/Updater.app" \
  "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE"; do
  /usr/bin/codesign --force --sign - --timestamp=none \
    --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$COMPONENT"
done
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
  --entitlements "$PROJECT_ROOT/TokenTick/Resources/TokenTick.entitlements" "$PACKAGE_DIR/TokenTick.app"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$CLI_EXECUTABLE"
/usr/bin/codesign --verify --deep --strict "$PACKAGE_DIR/TokenTick.app"
/usr/bin/codesign --verify --strict "$CLI_EXECUTABLE"
/usr/bin/codesign -dvvv "$PACKAGE_DIR/TokenTick.app" >"$PACKAGE_DIR/App-signature.txt" 2>&1
/usr/bin/codesign -dvvv "$CLI_EXECUTABLE" >"$PACKAGE_DIR/CLI-signature.txt" 2>&1
for EXECUTABLE in "$APP_EXECUTABLE" "$CLI_EXECUTABLE"; do
  [ "$(/usr/bin/lipo -archs "$EXECUTABLE")" = "arm64" ] || { echo "Artifacts must contain only arm64." >&2; exit 1; }
done
"$CLI_EXECUTABLE" --help >"$LOG_DIR/release-cli-help.log"
"$PACKAGE_DIR/TokenTick.app/Contents/Helpers/tokentick" --help >"$LOG_DIR/release-embedded-cli-help.log"

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
echo "Release distribution: $ARCHIVE"
echo "Checksum file: $ARCHIVE.sha256"
# The update archive contains only the app; Sparkle does not replace a separately installed CLI.
UPDATE_ARCHIVE="$STAGING/TokenTick-$VERSION.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR/TokenTick.app" "$UPDATE_ARCHIVE"
(cd "$STAGING" && /usr/bin/shasum -a 256 "TokenTick-$VERSION.zip" >"$UPDATE_ARCHIVE.sha256")
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "release_directory=$STAGING" >>"$GITHUB_OUTPUT"
  echo "update_archive=$UPDATE_ARCHIVE" >>"$GITHUB_OUTPUT"
fi
echo "App update archive: $UPDATE_ARCHIVE"
echo "Signing: ad-hoc, without notarization or a paid developer account. See the bundled README.md for installation. Requires macOS 26 and Apple Silicon."
