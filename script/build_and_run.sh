#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry|--preview-limits) ;;
  *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry|--preview-limits]" >&2; exit 2 ;;
esac

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/DebugDerivedData"
BUILD_LOG="$PROJECT_ROOT/.build/logs/app-build.log"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/TokenTick.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/TokenTick"
DEBUG_DATA_DIR="$PROJECT_ROOT/.build/debug-data"
mkdir -p "$(dirname "$BUILD_LOG")" "$DEBUG_DATA_DIR"
export TOKENTICK_DATABASE="$DEBUG_DATA_DIR/usage.sqlite"

# Match this checkout's debug executable, never another installed or running app.
debug_pids() {
  ps -axo pid=,comm= | awk -v executable="$APP_EXECUTABLE" '{ pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == executable) print pid }'
}
while IFS= read -r pid; do
  [ -z "$pid" ] || kill "$pid"
done < <(debug_pids)
set +e
xcodebuild -project "$PROJECT_ROOT/TokenTick.xcodeproj" \
  -scheme TokenTick -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" PRODUCT_BUNDLE_IDENTIFIER=com.yeliex.tokentick.debug \
  build >"$BUILD_LOG" 2>&1
BUILD_RESULT=$?
set -e
if [ "$BUILD_RESULT" -ne 0 ]; then
  awk '/error:|BUILD FAILED|failed:/ && count++ < 30 { print substr($0, 1, 1000) }' "$BUILD_LOG" >&2
  echo "Full build log: $BUILD_LOG" >&2
  exit "$BUILD_RESULT"
fi

echo "Build succeeded: $APP_BUNDLE"
if [ "$MODE" = "--debug" ]; then
  exec lldb -- "$APP_EXECUTABLE"
fi
if [ "$MODE" = "--preview-limits" ]; then
  /usr/bin/open -n "$APP_BUNDLE" --env "TOKENTICK_DATABASE=$TOKENTICK_DATABASE" --args --preview-limits
else
  /usr/bin/open -n "$APP_BUNDLE" --env "TOKENTICK_DATABASE=$TOKENTICK_DATABASE"
fi
case "$MODE" in
  --verify)
    sleep 1
    [ -n "$(debug_pids)" ]
    echo "TokenTick Debug started with isolated data: $DEBUG_DATA_DIR"
    ;;
  --logs)
    exec /usr/bin/log stream --info --style compact --predicate "processImagePath == \"$APP_EXECUTABLE\""
    ;;
  --telemetry)
    exec /usr/bin/log stream --info --style compact --predicate "processImagePath == \"$APP_EXECUTABLE\" AND subsystem == \"com.yeliex.tokentick\""
    ;;
esac
