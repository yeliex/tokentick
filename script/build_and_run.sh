#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry) ;;
  *) echo "用法：$0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/DerivedData"
BUILD_LOG="$PROJECT_ROOT/.build/logs/app-build.log"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/TokenTick.app"
mkdir -p "$(dirname "$BUILD_LOG")"

pkill -x TokenTick >/dev/null 2>&1 || true
set +e
xcodebuild -project "$PROJECT_ROOT/TokenTick.xcodeproj" \
  -scheme TokenTick -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" build >"$BUILD_LOG" 2>&1
BUILD_RESULT=$?
set -e
if [ "$BUILD_RESULT" -ne 0 ]; then
  awk '/error:|BUILD FAILED|failed:/ && count++ < 30 { print substr($0, 1, 1000) }' "$BUILD_LOG" >&2
  echo "完整构建日志：$BUILD_LOG" >&2
  exit "$BUILD_RESULT"
fi

echo "构建成功：$APP_BUNDLE"
if [ "$MODE" = "--debug" ]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/TokenTick"
fi
/usr/bin/open -n "$APP_BUNDLE"
case "$MODE" in
  --verify)
    sleep 1
    pgrep -x TokenTick >/dev/null
    echo "TokenTick 已启动。"
    ;;
  --logs)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "TokenTick"'
    ;;
  --telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.yeliex.tokentick"'
    ;;
esac
