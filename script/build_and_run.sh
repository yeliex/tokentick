#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry|--preview-limits) ;;
  *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry|--preview-limits]" >&2; exit 2 ;;
esac

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Use the same build location as Xcode for this checkout.
PRODUCTS="$(xcodebuild -project "$PROJECT_ROOT/TokenTick.xcodeproj" \
  -scheme TokenTick -configuration Debug -destination 'platform=macOS' \
  -showBuildSettings -json -quiet | /usr/bin/plutil -extract 0.buildSettings.BUILT_PRODUCTS_DIR raw -o - -)"
APP_BUNDLE="$PRODUCTS/TokenTick.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/TokenTick"

# Match this checkout's debug executable, never another installed or running app.
debug_pids() {
  ps -axo pid=,comm= | awk -v executable="$APP_EXECUTABLE" '{ pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == executable) print pid }'
}
while IFS= read -r pid; do
  [ -z "$pid" ] || kill "$pid"
done < <(debug_pids)
xcodebuild -project "$PROJECT_ROOT/TokenTick.xcodeproj" \
  -scheme TokenTick -configuration Debug -destination 'platform=macOS' \
  PRODUCT_BUNDLE_IDENTIFIER=com.yeliex.tokentick.debug \
  -quiet build

echo "Build succeeded: $APP_BUNDLE"
if [ "$MODE" = "--debug" ]; then
  exec lldb -- "$APP_EXECUTABLE"
fi
if [ "$MODE" = "--preview-limits" ]; then
  /usr/bin/open -n "$APP_BUNDLE" --args --preview-limits
else
  /usr/bin/open -n "$APP_BUNDLE"
fi
case "$MODE" in
  --verify)
    sleep 1
    [ -n "$(debug_pids)" ]
    echo "TokenTick Debug started."
    ;;
  --logs)
    exec /usr/bin/log stream --info --style compact --predicate "processImagePath == \"$APP_EXECUTABLE\""
    ;;
  --telemetry)
    exec /usr/bin/log stream --info --style compact --predicate "processImagePath == \"$APP_EXECUTABLE\" AND subsystem == \"com.yeliex.tokentick\""
    ;;
esac
